// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SplitV3Reference}      from "../../src/references/SplitV3Reference.sol";
import {IUniswapV3PoolMinimal} from "../../src/interfaces/IUniswapV3PoolMinimal.sol";
import {PoolId}                from "v4-core/types/PoolId.sol";

/// @notice The reference reader, against the live mainnet pools it is configured for.
///
/// Everything else in this suite runs against a mock oracle: the mock proves the hook
/// does the right thing GIVEN a reference, and proves nothing about whether the reader
/// produces one. These tests close that gap. Each one recomputes the reader's output
/// from the raw pool calls and asserts equality, so a wrong pool, a misparsed `slot0`
/// tuple, a dropped truncation correction, or an inverted divergence signal fails here
/// rather than on a live pool.
///
///   forge test --match-contract ReplayForkTest --fork-url $MAINNET_RPC_URL
///   MAINNET_RPC_URL=... FORK_BLOCK=25785425 forge test --match-contract ReplayForkTest
///
/// Either form works: `--fork-url` is detected by chain id, `MAINNET_RPC_URL` creates
/// the fork here (and honours FORK_BLOCK for a deterministic run). With neither, the
/// suite skips rather than failing. The assertions hold at any block.
contract ReplayForkTest is Test {
    // From discover.py — the two pools the shipped config names.
    address constant FAST_POOL = 0xE0554a476A092703abdB3Ef35c80e0D76d32939F; // v3 0.01% ETH/USDC
    address constant DEEP_POOL = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // v3 0.05% ETH/USDC

    uint32 constant WINDOW     = 1800;
    uint24 constant GUARD_DEV  = 50;
    uint24 constant FREEZE_DEV = 250;

    /// @dev observe() over 30 days exceeds any plausible observation cardinality, so it
    ///      reverts with OLD. Used to exercise the try/catch on live data.
    uint32 constant IMPOSSIBLE_WINDOW = 30 days;

    SplitV3Reference ref;
    PoolId constant ID    = PoolId.wrap(bytes32(uint256(1)));
    PoolId constant UNSET = PoolId.wrap(bytes32(uint256(999)));
    bool   skipAll;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));

        if (bytes(rpc).length != 0) {
            uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
            if (blk == 0) vm.createSelectFork(rpc);
            else          vm.createSelectFork(rpc, blk);
        } else if (block.chainid == 31337) {
            // No RPC in the env and no --fork-url: nothing to read.
            skipAll = true;
            return;
        }
        // else: already forked by --fork-url, use the active fork as-is.

        require(block.chainid == 1, "these pools are mainnet-only");
        ref = new SplitV3Reference(address(this));
        _configure(WINDOW, FREEZE_DEV, false);
    }

    modifier onlyFork() { vm.skip(skipAll); _; }

    function _configure(uint32 window, uint24 freezeDev, bool invert) internal {
        ref.setConfig(ID, SplitV3Reference.Config({
            fastPool:          FAST_POOL,
            deepPool:          DEEP_POOL,
            twapWindow:        window,
            guardMaxDevTicks:  GUARD_DEV,
            freezeMaxDevTicks: freezeDev,
            invertTicks:       invert
        }));
    }

    function _spot(address pool) internal view returns (int24 t) {
        (, t,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
    }

    /// @dev The TWAP, recomputed here independently of the reader — including the
    ///      round-toward-zero correction the reader applies.
    function _twap(address pool, uint32 window) internal view returns (int24) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = window; ago[1] = 0;
        (int56[] memory cum,) = IUniswapV3PoolMinimal(pool).observe(ago);
        int56 delta = cum[1] - cum[0];
        int56 w     = int56(uint56(window));
        int24 t     = int24(delta / w);
        if (delta < 0 && (delta % w != 0)) t--;
        return t;
    }

    function _abs(int24 x) internal pure returns (uint24) {
        return uint24(x >= 0 ? x : -x);
    }

    // ---------------------------------------------------------------- reads

    /// @notice The reference is the fast pool's spot tick, and the divergence signal is
    ///         the worse of (deep vs its own TWAP) and (fast vs deep) — recomputed here
    ///         from the raw calls, not taken on trust.
    function test_ReferenceMatchesIndependentlyComputedValues() public onlyFork {
        int24 fast     = _spot(FAST_POOL);
        int24 deep     = _spot(DEEP_POOL);
        int24 deepTwap = _twap(DEEP_POOL, WINDOW);

        uint24 dDeep    = _abs(deep - deepTwap);
        uint24 dFast    = _abs(fast - deep);
        uint24 expected = dDeep > dFast ? dDeep : dFast;

        (int24 tick, bool ok, uint24 divTicks) = ref.getRefTick(ID);

        emit log_named_int("fast spot",  fast);
        emit log_named_int("deep spot",  deep);
        emit log_named_int("deep TWAP",  deepTwap);
        emit log_named_uint("divergence", divTicks);

        assertTrue(ok, "live read must succeed at this block");
        assertEq(tick, fast, "reference is the fast pool's spot tick");
        assertEq(divTicks, expected, "divergence is max(deep-vs-TWAP, fast-vs-deep)");
    }

    /// @notice The two pools quote the same asset. If the reader were pointed at the
    ///         wrong pool, or `slot0`'s tuple were misparsed, they would not agree.
    function test_BothPoolsQuoteTheSameAsset() public onlyFork {
        int24 fast = _spot(FAST_POOL);
        int24 deep = _spot(DEEP_POOL);
        assertLt(_abs(fast - deep), 500, "two ETH/USDC pools within 5%");
        // ETH/USDC sits around |196,000| ticks. A wide band, but it excludes 0, a
        // reversed pair, and any non-ETH/USDC pool.
        assertGt(_abs(fast), 100_000, "tick magnitude is ETH/USDC-shaped");
        assertLt(_abs(fast), 300_000, "tick magnitude is ETH/USDC-shaped");
    }

    /// @notice Deployment prerequisite: the deep pool's observation cardinality covers
    ///         the configured window. If this ever fails on a target chain, the hook
    ///         freezes on every swap until someone calls
    ///         increaseObservationCardinalityNext.
    function test_DeepPoolServesTheGuardWindow() public onlyFork {
        assertTrue(ref.isReady(ID), "deep pool must serve the 1800s window");
    }

    // ---------------------------------------------------------------- freeze

    /// @notice A window no pool can serve makes observe() revert. The reader must
    ///         freeze, not propagate — an unguarded revert here reaches beforeSwap and
    ///         bricks every trade in the pool.
    function test_ImpossibleWindowFreezesInsteadOfReverting() public onlyFork {
        _configure(IMPOSSIBLE_WINDOW, FREEZE_DEV, false);
        assertFalse(ref.isReady(ID), "cannot serve a 30-day window");
        (int24 tick, bool ok,) = ref.getRefTick(ID);   // must not revert
        assertFalse(ok, "freeze");
        assertEq(tick, 0);
    }

    /// @notice A freeze threshold below live divergence freezes, and still reports the
    ///         divergence that caused it.
    function test_FreezeThresholdBindsOnLiveDivergence() public onlyFork {
        _configure(WINDOW, 1, false);
        (int24 tick, bool ok, uint24 divTicks) = ref.getRefTick(ID);
        if (divTicks <= 1) {
            assertTrue(ok, "live divergence is 0 or 1 ticks: nothing to freeze on");
        } else {
            assertFalse(ok, "must freeze above the threshold");
            assertEq(tick, 0);
            assertGt(divTicks, 1, "and report why");
        }
    }

    function test_UnconfiguredPoolFreezes() public onlyFork {
        (int24 tick, bool ok, uint24 divTicks) = ref.getRefTick(UNSET);
        assertFalse(ok); assertEq(tick, 0); assertEq(divTicks, 0);
    }

    // ---------------------------------------------------------------- invert

    /// @notice `invertTicks` is the bit that decides whether a v4 pool with the opposite
    ///         token order reads a ~400,000-tick phantom gap. Against live data it must
    ///         flip the sign and leave divergence alone.
    function test_InvertTicksFlipsSignOnLiveData() public onlyFork {
        (int24 plain,, uint24 d1) = ref.getRefTick(ID);
        _configure(WINDOW, FREEZE_DEV, true);
        (int24 inv, bool ok, uint24 d2) = ref.getRefTick(ID);
        assertTrue(ok);
        assertEq(inv, -plain, "sign flipped");
        assertEq(d2, d1, "divergence is computed in the v3 frame, before inversion");
    }

    // ---------------------------------------------------------------- gas

    /// @notice Two slot0 reads plus one observe. This is the per-swap cost the hook pays
    ///         for its reference, and the number quoted in the README.
    function test_ReferenceGasUnderCeiling() public onlyFork {
        uint256 before_ = gasleft();
        (, bool ok,) = ref.getRefTick(ID);
        uint256 used = before_ - gasleft();
        emit log_named_uint("getRefTick gas (cold storage, warm pools)", used);
        assertTrue(ok);
        assertLt(used, 80_000, "reference read must stay well under a swap's budget");
    }
}
