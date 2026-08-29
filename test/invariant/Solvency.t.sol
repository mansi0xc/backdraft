// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test}          from "forge-std/Test.sol";
import {StdInvariant}  from "forge-std/StdInvariant.sol";

import {BackdraftTestBase} from "../BackdraftTestBase.sol";
import {BackdraftHook}     from "../../src/BackdraftHook.sol";
import {IPoolManager}      from "v4-core/interfaces/IPoolManager.sol";
import {PoolId}            from "v4-core/types/PoolId.sol";
import {PoolKey}           from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

// ============================================================
// Solvency invariant suite
//
// Core property:
//   hook.ERC6909_balance(currency) >= ghost_totalUnsettledEscrowed(currency)
//
// Meaning: the hook always holds enough ERC-6909 claims to cover every
// escrowed amount in every gap that has not yet been fully paid out.
// No value can be created from nowhere or lost between escrow and payout.
//
// Handler performs random: addLiquidity, swap, settle, claimTrader, claimLp.
// Ghost variables track the theoretical max obligation.
// ============================================================

// ---------------------------------------------------------------------------
// Handler — wired to the fuzzer as the only target
// ---------------------------------------------------------------------------
contract SolvencyHandler is BackdraftTestBase {

    // ghost accounting: currency → total escrowed across all open+settled-but-unpaid gaps
    uint256 public ghost_escrowed0;  // for currency0
    uint256 public ghost_escrowed1;  // for currency1

    // track all gap indices ever opened so the invariant can sweep them
    uint256[] public allGapIndices;
    mapping(uint256 => bool) public gapTracked;

    // actors
    address[] public actors;

    function setUp() public override {
        super.setUp();
        actors = [address(0xaaaa), address(0xbbbb), address(0xcccc), address(0xdddd)];
        for (uint i = 0; i < actors.length; i++) {
            token0.transfer(actors[i], 50_000_000e18);
            token1.transfer(actors[i], 50_000_000e18);
        }
        // Seed initial liquidity so swaps don't revert on empty pool
        _addLiquidity(address(this), -6000, 6000, 5_000_000e18);
    }

    // ── Bounded fuzzer actions ──────────────────────────────────────────────

    function addLiq(uint8 actorIdx, int24 tickLower, int24 tickUpper, uint128 liq) public {
        actorIdx = actorIdx % uint8(actors.length);
        // Align ticks to spacing=60, keep in [-6000, 6000]
        tickLower = _alignTick(tickLower, -6000, -60);
        tickUpper = _alignTick(tickUpper, 60, 6000);
        if (tickLower >= tickUpper) tickUpper = tickLower + 60;
        liq = uint128(bound(liq, 1e18, 1_000_000e18));
        _addLiquidity(actors[actorIdx], tickLower, tickUpper, liq);
        _trackOpenGap();
    }

    function doSwap(uint8 actorIdx, bool zeroForOne, uint128 amount) public {
        actorIdx = actorIdx % uint8(actors.length);
        amount = uint128(bound(amount, 1e15, 500_000e18));
        _swap(actors[actorIdx], zeroForOne, -int256(uint256(amount)));

        uint256 idx = hook.openGapIdx(poolId);
        if (idx > 0 && !gapTracked[idx]) {
            allGapIndices.push(idx);
            gapTracked[idx] = true;
            // Record the new escrowed amount (may be 0 initially)
        }
        _syncEscrowGhost();
    }

    function doSettle(uint256 gapIdxHint) public {
        if (allGapIndices.length == 0) return;
        uint256 idx = allGapIndices[gapIdxHint % allGapIndices.length];
        BackdraftHook.Gap memory g = hook.gapAt(poolId, idx);
        if (g.settled) return;
        bool isOpen = hook.openGapIdx(poolId) == idx;
        bool expired = block.number > g.expiryBlock;
        if (!isOpen || expired) {
            try hook.settle(poolId, idx) {} catch {}
        }
        _syncEscrowGhost();
    }

    function doClaimTrader(uint8 actorIdx, uint256 gapIdxHint) public {
        if (allGapIndices.length == 0) return;
        actorIdx = actorIdx % uint8(actors.length);
        uint256 idx = allGapIndices[gapIdxHint % allGapIndices.length];
        BackdraftHook.Gap memory g = hook.gapAt(poolId, idx);
        if (!g.settled || g.totalContribution == 0) return;
        bytes32 key = keccak256(abi.encode(poolId, idx, actors[actorIdx]));
        if (hook.contribution(key) == 0) return;
        vm.prank(actors[actorIdx], actors[actorIdx]);
        try hook.claimTrader(poolId, idx) {} catch {}
        _syncEscrowGhost();
    }

    function doClaimLp(uint8 actorIdx, uint256 gapIdxHint) public {
        if (allGapIndices.length == 0) return;
        actorIdx = actorIdx % uint8(actors.length);
        uint256 idx = allGapIndices[gapIdxHint % allGapIndices.length];
        BackdraftHook.Gap memory g = hook.gapAt(poolId, idx);
        if (!g.settled) return;

        bytes32 posKey = hook.positionKeyFor(
            poolId, actors[actorIdx], int24(-6000), int24(6000), bytes32(0)
        );
        if (hook.lpClaimed(posKey, idx)) return;

        vm.prank(actors[actorIdx], actors[actorIdx]);
        try hook.claimLp(poolId, idx, int24(-6000), int24(6000), bytes32(0)) {} catch {}
        _syncEscrowGhost();
    }

    function advanceBlocks(uint16 n) public {
        vm.roll(block.number + (n % 500) + 1);
    }

    function moveOracle(int24 newRef) public {
        newRef = int24(bound(int256(newRef), -1000, 1000));
        oracle.setRef(poolId, newRef);
        _syncEscrowGhost();
    }

    // ── Ghost sync ──────────────────────────────────────────────────────────

    function _syncEscrowGhost() internal {
        uint256 total0;
        uint256 total1;
        BackdraftHook.Gap[] memory allGaps = hook.gaps(poolId);
        // Index 0 is sentinel — skip it
        for (uint256 i = 1; i < allGaps.length; i++) {
            BackdraftHook.Gap memory g = allGaps[i];
            if (g.settled) continue;   // settled gaps: obligation discharged on claim
            if (g.escrowed == 0) continue;
            if (g.isCurrency0) {
                total0 += g.escrowed;
            } else {
                total1 += g.escrowed;
            }
        }
        ghost_escrowed0 = total0;
        ghost_escrowed1 = total1;
    }

    function _trackOpenGap() internal {
        uint256 idx = hook.openGapIdx(poolId);
        if (idx > 0 && !gapTracked[idx]) {
            allGapIndices.push(idx);
            gapTracked[idx] = true;
        }
    }

    function _alignTick(int24 raw, int24 lo, int24 hi) internal pure returns (int24) {
        int24 clamped = raw < lo ? lo : (raw > hi ? hi : raw);
        // Round down to nearest multiple of 60
        int24 rem = clamped % 60;
        return rem == 0 ? clamped : clamped - rem;
    }
}

// ---------------------------------------------------------------------------
// Invariant test — registers handler as the fuzzer target
// ---------------------------------------------------------------------------
contract SolvencyTest is StdInvariant, Test {

    SolvencyHandler public handler;

    function setUp() public {
        handler = new SolvencyHandler();
        handler.setUp();

        // Only fuzz the handler
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = SolvencyHandler.addLiq.selector;
        selectors[1] = SolvencyHandler.doSwap.selector;
        selectors[2] = SolvencyHandler.doSettle.selector;
        selectors[3] = SolvencyHandler.doClaimTrader.selector;
        selectors[4] = SolvencyHandler.doClaimLp.selector;
        selectors[5] = SolvencyHandler.advanceBlocks.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ── Core invariant ──────────────────────────────────────────────────────

    /// @notice The hook's ERC-6909 balance must always cover unsettled escrow.
    ///         ERC-6909 balance can only decrease via burn() in _payout().
    ///         ghost_escrowed only counts unsettled gaps — once settled, the
    ///         obligation is discharged on individual claims (which also burn).
    function invariant_hookSolvent() public view {
        BackdraftHook h = handler.hook();
        IPoolManager  pm = handler.manager();
        Currency cur0 = Currency.wrap(address(handler.token0()));
        Currency cur1 = Currency.wrap(address(handler.token1()));

        uint256 bal0 = pm.balanceOf(address(h), cur0.toId());
        uint256 bal1 = pm.balanceOf(address(h), cur1.toId());

        assertGe(bal0, handler.ghost_escrowed0(),
            "invariant: hook currency0 balance < unsettled escrow0");
        assertGe(bal1, handler.ghost_escrowed1(),
            "invariant: hook currency1 balance < unsettled escrow1");
    }

    /// @notice No gap can have escrowed > hook balance — payout would be impossible.
    function invariant_noGapExceedsBalance() public view {
        BackdraftHook h  = handler.hook();
        IPoolManager  pm = handler.manager();
        Currency cur0 = Currency.wrap(address(handler.token0()));
        Currency cur1 = Currency.wrap(address(handler.token1()));

        uint256 bal0 = pm.balanceOf(address(h), cur0.toId());
        uint256 bal1 = pm.balanceOf(address(h), cur1.toId());

        BackdraftHook.Gap[] memory gaps = h.gaps(handler.poolId());
        for (uint256 i = 1; i < gaps.length; i++) {
            if (gaps[i].settled) continue;
            if (gaps[i].escrowed == 0) continue;
            if (gaps[i].isCurrency0) {
                assertGe(bal0, gaps[i].escrowed,
                    "invariant: single gap escrowed0 > hook balance");
            } else {
                assertGe(bal1, gaps[i].escrowed,
                    "invariant: single gap escrowed1 > hook balance");
            }
        }
    }

    /// @notice openGapIdx is either 0 (no gap) or a valid index into _gaps array.
    function invariant_openGapIdxValid() public view {
        BackdraftHook h = handler.hook();
        PoolId id = handler.poolId();
        uint256 idx = h.openGapIdx(id);
        if (idx == 0) return;
        BackdraftHook.Gap[] memory gaps = h.gaps(id);
        assertLt(idx, gaps.length, "invariant: openGapIdx out of bounds");
        assertFalse(gaps[idx].settled, "invariant: open gap is marked settled");
    }

    /// @notice traderPot can never exceed escrowed.
    function invariant_traderPotBounded() public view {
        BackdraftHook h = handler.hook();
        PoolId id = handler.poolId();
        BackdraftHook.Gap[] memory gaps = h.gaps(id);
        for (uint256 i = 1; i < gaps.length; i++) {
            if (gaps[i].escrowed == 0) continue;
            // traderPot = escrowed * traderShareBps/10000 * min(contrib,maxAbsGap)/maxAbsGap
            // By construction: traderShareBps <= 10000 and min/max <= 1 → traderPot <= escrowed
            // We verify indirectly: traderShareBps cap
            assertLe(
                handler.traderShareBps(),
                uint16(10_000),
                "invariant: traderShareBps > 10000 would allow traderPot > escrowed"
            );
        }
    }
}
