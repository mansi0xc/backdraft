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
import {IPoolManager as IPM} from "v4-core/interfaces/IPoolManager.sol";

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
    struct Range { int24 lo; int24 hi; bytes32 salt; }
    mapping(address => Range) public lastRange;
    uint256 internal saltNonce;

    /// @dev A fresh salt per add. The v4-core test router keys every position under
    ///      its OWN address, so two adds to the same (range, salt) merge into one
    ///      router position; a top-up whose accrued fees exceed its principal then
    ///      trips the router's delta-sign assert. That is a harness artifact, not a
    ///      hook property, and unique salts remove it.
    function _salt(uint8) internal returns (bytes32) {
        return bytes32(++saltNonce);
    }

    function _addLiquiditySalted(address lp, int24 lo, int24 hi, uint128 liq, bytes32 salt) internal {
        vm.startPrank(lp, lp);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lo, tickUpper: hi, liquidityDelta: int256(uint256(liq)), salt: salt
            }),
            abi.encode(lp)
        );
        vm.stopPrank();
    }

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
        bytes32 salt = _salt(actorIdx);
        _addLiquiditySalted(actors[actorIdx], tickLower, tickUpper, liq, salt);
        lastRange[actors[actorIdx]] = Range(tickLower, tickUpper, salt);
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

        Range memory r = lastRange[actors[actorIdx]];
        if (r.lo == r.hi) return;
        bytes32 posKey = hook.positionKeyFor(poolId, actors[actorIdx], r.lo, r.hi, r.salt);
        if (hook.lpClaimed(posKey, idx)) return;

        vm.prank(actors[actorIdx], actors[actorIdx]);
        try hook.claimLp(poolId, idx, r.lo, r.hi, r.salt) {} catch {}
        _syncEscrowGhost();
    }

    function doSweep(uint256 gapIdxHint) public {
        if (allGapIndices.length == 0) return;
        uint256 idx = allGapIndices[gapIdxHint % allGapIndices.length];
        try hook.sweepUnclaimed(poolId, idx) {} catch {}
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
            if (g.swept) continue;     // swept: nothing further can be claimed
            if (g.escrowed == 0) continue;
            // Outstanding obligation, settled or not: what has been escrowed and not
            // yet paid. A settled-but-unclaimed gap is still owed.
            uint256 owed = uint256(g.escrowed) - uint256(g.lpPaid) - uint256(g.traderPaid);
            if (g.isCurrency0) {
                total0 += owed;
            } else {
                total1 += owed;
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

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = SolvencyHandler.addLiq.selector;
        selectors[1] = SolvencyHandler.doSwap.selector;
        selectors[2] = SolvencyHandler.doSettle.selector;
        selectors[3] = SolvencyHandler.doClaimTrader.selector;
        selectors[4] = SolvencyHandler.doClaimLp.selector;
        selectors[5] = SolvencyHandler.advanceBlocks.selector;
        selectors[6] = SolvencyHandler.moveOracle.selector;
        selectors[7] = SolvencyHandler.doSweep.selector;
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

    /// @notice Paid never exceeds pot, per gap: lpPaid <= lpPot and traderPaid <= traderPot.
    function invariant_paidNeverExceedsPot() public view {
        BackdraftHook h = handler.hook();
        PoolId id = handler.poolId();
        BackdraftHook.Gap[] memory gaps = h.gaps(id);
        uint16 share = handler.traderShareBps();
        for (uint256 i = 1; i < gaps.length; i++) {
            BackdraftHook.Gap memory g = gaps[i];
            if (g.escrowed == 0) continue;
            uint256 explained = g.totalContribution > g.maxAbsGap ? g.maxAbsGap : g.totalContribution;
            uint256 tp = g.maxAbsGap == 0 ? 0
                : (uint256(g.escrowed) * share * explained) / (uint256(g.maxAbsGap) * 10_000);
            assertLe(g.traderPaid, tp, "traderPaid > traderPot");
            assertLe(g.lpPaid, uint256(g.escrowed) - tp, "lpPaid > lpPot");
        }
    }
}
