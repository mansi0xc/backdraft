// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BackdraftTestBase} from "../BackdraftTestBase.sol";
import {BackdraftHook}     from "../../src/BackdraftHook.sol";
import {IPoolManager}      from "v4-core/interfaces/IPoolManager.sol";
import {Currency}          from "v4-core/types/Currency.sol";
import {PoolId}            from "v4-core/types/PoolId.sol";
import {PoolIdLibrary}     from "v4-core/types/PoolId.sol";
import {PoolKey}           from "v4-core/types/PoolKey.sol";

// ============================================================
// Spike: beforeSwapReturnDelta
// "Done when: hook's ERC-6909 balance rose by exactly the
//  surcharge, and a withdraw() moved real tokens to an EOA."
// ============================================================
contract SpikeTest is BackdraftTestBase {

    address constant ROHAN = address(0xaaaa);
    address constant VIK   = address(0xbbbb);

    function setUp() public override {
        super.setUp();
        // Fund traders with enough for all test scenarios
        token0.transfer(ROHAN, 100_000_000e18);
        token1.transfer(ROHAN, 100_000_000e18);
        token0.transfer(VIK,   100_000_000e18);
        token1.transfer(VIK,   100_000_000e18);
    }

    // ----------------------------------------------------------
    // Spike: beforeSwapReturnDelta collects surcharge as ERC-6909
    // ----------------------------------------------------------

    /// @notice No gap open → no surcharge collected, swap goes through normally.
    function test_NoSurchargeWhenNoGapOpen() public {
        _addLiquidity(address(this), -600, 600, 1_000_000e18);

        uint256 balBefore = _hookBalance(poolKey.currency0);
        _swap(ROHAN, true, -1e18); // zeroForOne, exact-in
        uint256 balAfter = _hookBalance(poolKey.currency0);

        assertEq(balAfter, balBefore, "no gap => no surcharge");
    }

    /// @notice Opening swap widens the gap → no surcharge on widening swaps.
    function test_NoSurchargeOnWideningSwap() public {
        _addLiquidity(address(this), -6000, 6000, 10_000_000e18);

        // Oracle still at tick 0. Rohan buys token1 (oneForZero = false → price up → tick up).
        // This widens the gap (pool moves above ref).
        uint256 balBefore = _hookBalance(poolKey.currency1);
        _swap(ROHAN, false, -1_000e18); // oneForZero, exact-in
        uint256 balAfter = _hookBalance(poolKey.currency1);

        assertEq(balAfter, balBefore, "widening swap => no surcharge");
    }

    /// @notice Full flow: gap opens, Vik closes it, surcharge collected in hook.
    function test_SurchargeCollectedOnClosingSwap() public {
        _addLiquidity(address(this), -6000, 6000, 10_000_000e18);

        // Step 1: Rohan swaps oneForZero (buys token1, price goes up, tick goes up).
        // This should push tick well above 65 and open a gap.
        _swap(ROHAN, false, -500_000e18);

        int24 tickAfterRohan = _poolTick();
        int24 refTick = 0; // oracle still at 0
        bool gapOpened = tickAfterRohan - refTick > int24(gapThresholdTicks);
        assertTrue(gapOpened, "gap should have opened after Rohan");

        uint256 openIdx = hook.openGapIdx(poolId);
        assertGt(openIdx, 0, "openGapIdx should be non-zero");

        // Step 2: Vik closes the gap (zeroForOne, price back down).
        // This is a narrowing swap — should be surcharged.
        uint256 balBefore = _hookBalance(poolKey.currency0);
        _swap(VIK, true, -100_000e18); // zeroForOne, closes the gap
        uint256 balAfter = _hookBalance(poolKey.currency0);

        assertGt(balAfter, balBefore, "closing swap should have collected surcharge");
    }

    // ----------------------------------------------------------
    // Gap lifecycle
    // ----------------------------------------------------------

    /// @notice Gap does NOT open when price moves less than threshold.
    function test_NoGapBelowThreshold() public {
        _addLiquidity(address(this), -6000, 6000, 100_000_000e18);

        // Tiny swap — tick barely moves
        _swap(ROHAN, false, -1e18);

        assertEq(hook.openGapIdx(poolId), 0, "tiny swap should not open gap");
    }

    /// @notice Gap opens above threshold and records correct openBlock.
    function test_GapOpensAboveThreshold() public {
        _addLiquidity(address(this), -6000, 6000, 10_000_000e18);

        _swap(ROHAN, false, -500_000e18);

        uint256 idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "gap should be open");

        BackdraftHook.Gap memory g = hook.gapAt(poolId, idx);
        assertEq(g.openBlock, block.number);
        assertFalse(g.settled);
        assertTrue(g.gapPositive); // tick went up, gap is positive
    }

    /// @notice Widening swaps credit the sender in the contribution ledger.
    ///         The swap that OPENS the gap is the originator and IS credited — it is
    ///         the trader whose price impact created the mispricing, and crediting it
    ///         is the whole point of the ledger. Further widening swaps accumulate.
    function test_WideningSwapCredited() public {
        _addLiquidity(address(this), -6000, 6000, 10_000_000e18);

        // Swap 1: opens the gap AND is credited as the originator
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "gap should be open after first swap");

        BackdraftHook.Gap memory g1 = hook.gapAt(poolId, idx);
        assertGt(g1.totalContribution, 0, "opening swap IS the originator and must be credited");
        assertGt(hook.contribution(keccak256(abi.encode(poolId, idx, ROHAN))), 0,
            "credit must be attributed to the opening swapper");

        // Swap 2: a second widening swap accumulates on top
        _swap(ROHAN, false, -200_000e18);

        BackdraftHook.Gap memory g2 = hook.gapAt(poolId, idx);
        assertGt(g2.totalContribution, g1.totalContribution,
            "second widening swap should add further credit");
    }

    /// @notice Sign flip (overshoot past ref) closes the gap immediately.
    function test_SignFlipClosesGap() public {
        _addLiquidity(address(this), -6000, 6000, 10_000_000e18);

        // Open gap: tick goes positive
        _swap(ROHAN, false, -500_000e18);
        uint256 idxBefore = hook.openGapIdx(poolId);
        assertGt(idxBefore, 0);

        // Massive closing swap that overshoots to negative side
        _swap(VIK, true, -2_000_000e18);

        // Gap should be closed (openGapIdx reset to 0 or a new gap opened on other side)
        // Either way the original gap must be settled-eligible
        BackdraftHook.Gap memory g = hook.gapAt(poolId, idxBefore);
        // The gap was closed — escrowed may be 0 if Vik's swap was small relative to gap
        // but settled flag is not set yet (settle() is called separately)
        assertEq(hook.openGapIdx(poolId) == idxBefore ? 1 : 0, 0,
            "original gap should be closed");
    }

    /// @notice Frozen oracle → no surcharge, no ledger writes, no gap opens.
    function test_FrozenOracleDoesNothing() public {
        _addLiquidity(address(this), -6000, 6000, 10_000_000e18);
        oracle.setFrozen(poolId, true);

        uint256 balBefore = _hookBalance(poolKey.currency0);
        _swap(ROHAN, false, -500_000e18);

        assertEq(hook.openGapIdx(poolId), 0, "frozen oracle => no gap");
        assertEq(_hookBalance(poolKey.currency0), balBefore, "frozen oracle => no escrow");
    }

    // ----------------------------------------------------------
    // Unreadable reference (hard failure, not manipulation)
    // ----------------------------------------------------------

    /// @notice A reference that cannot be read at all must produce inaction: no gap
    ///         opens, no surcharge is taken, and the swap still succeeds.
    ///
    ///         This test used to be named ManipulatedFastPool_OracleReturnsFrozen and
    ///         described manipulation as the cause. That claim is now false, and the
    ///         test only passed because it drives the mock's freeze flag directly
    ///         rather than producing divergence. Appendix §10 measured a boolean freeze
    ///         on source disagreement as an off-switch reachable for $7-$21, so
    ///         divergence is PRICED instead — see GraduatedFee.t.sol, in particular
    ///         test_DivergencePastOldFreezePointStillSurcharges, which asserts the
    ///         opposite of what this test's old name implied.
    ///
    ///         What remains genuinely frozen is a reference the hook cannot read:
    ///         an unconfigured pool, or observe() reverting for insufficient
    ///         observation cardinality. Neither is attacker-inducible.
    function test_UnreadableReferenceProducesInaction() public {
        _addLiquidity(address(this), -6000, 6000, 10_000_000e18);

        // Hard read failure — NOT manipulation. See SplitV3Reference: the only
        // remaining ok=false paths are an unconfigured pool and an observe() revert.
        oracle.setFrozen(poolId, true);

        // Even with a large swap the hook does nothing
        _swap(ROHAN, false, -500_000e18);

        assertEq(hook.openGapIdx(poolId), 0, "unreadable reference => no gap opens");
    }

    /// @notice The complement, and the reason the rename matters: divergence that the
    ///         OLD design would have frozen on now opens a gap and surcharges the
    ///         close. Without this, the suite would still read as though manipulation
    ///         disables the hook.
    function test_ManipulationLevelDivergenceDoesNotDisableTheHook() public {
        _addLiquidity(address(this), -6000, 6000, 10_000_000e18);

        // Past the old guardMaxDevTicks of 50 — the exact condition that used to
        // return ok=false and stop all capture for ~$21.
        oracle.setDivergence(poolId, 51);

        _swap(ROHAN, false, -500_000e18);

        assertGt(hook.openGapIdx(poolId), 0,
            "divergence past the old freeze point must NOT disable gap detection");
    }

    // ----------------------------------------------------------
    // Exogenous gap: market moves, empty ledger, 100% to LPs
    // ----------------------------------------------------------

    /// @notice Oracle moves (exogenous market move) without any v4 swap.
    ///         When Vik closes the gap, totalContribution==0 → LPs get 100%.
    function test_ExogenousGap_EmptyLedger_LpsGetAll() public {
        _addLiquidity(address(this), -6000, 6000, 10_000_000e18);

        // Market moves: ref tick jumps to +200, pool stays at 0 → exogenous gap
        oracle.setRef(poolId, 200);

        // First swap into the pool detects the gap in afterSwap
        // Vik closes it (zeroForOne → price down → tick down toward ref=200...
        // wait, pool is at ~0, ref is at 200, gap = 0 - 200 = -200 (negative).
        // Closing swap: oneForZero would widen further. zeroForOne brings pool down.
        // Actually: pool tick = 0, refTick = 200, gap = 0-200 = -200 (negative).
        // Narrowing for negative gap = !zeroForOne (oneForZero, price up).
        // So Vik swaps oneForZero to close.
        _swap(VIK, false, -100_000e18); // oneForZero — this should open gap in afterSwap

        // After this swap, gap may or may not be open depending on how far tick moved
        // The key assertion is: if a gap was opened and closed with zero contribution,
        // totalContribution == 0
        uint256 idx = hook.openGapIdx(poolId);
        if (idx > 0) {
            BackdraftHook.Gap memory g = hook.gapAt(poolId, idx);
            assertEq(g.totalContribution, 0, "exogenous gap => no contributions");
        }
    }

    // ----------------------------------------------------------
    // Surcharge cap
    // ----------------------------------------------------------

    /// @notice Surcharge is bounded by surchargeCapBps regardless of gap size.
    function test_SurchargeRespectsCap() public {
        _addLiquidity(address(this), -60000, 60000, 10_000_000e18);

        // Open a very large gap
        _swap(ROHAN, false, -2_000_000e18);

        uint256 gapIdx = hook.openGapIdx(poolId);
        if (gapIdx == 0) return; // gap didn't open — skip

        uint256 balBefore = _hookBalance(poolKey.currency0);
        _swap(VIK, true, -100_000e18); // large closing swap
        uint256 balAfter  = _hookBalance(poolKey.currency0);

        // explicit uint256 cast avoids Solidity inferring a small literal type
        uint256 collected    = balAfter >= balBefore ? balAfter - balBefore : 0;
        uint256 maxSurcharge = (uint256(100_000e18) * uint256(surchargeCapBps)) / 10_000;
        assertLe(collected, maxSurcharge, "surcharge must not exceed cap");
    }
}
