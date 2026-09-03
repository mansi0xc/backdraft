// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BackdraftTestBase} from "../BackdraftTestBase.sol";
import {BackdraftHook}     from "../../src/BackdraftHook.sol";
import {console}           from "forge-std/console.sol";

// ============================================================
// Splitting-resistance regression tests.
//
// History: the surcharge was priced on the gap prevailing at each swap. Each leg of a
// split close sees a smaller gap than the last, so the rate decays across the sequence
// and the total collected approaches the integral of a linear function from 0 to G
// rather than its value at G. Measured on the unpatched branch, same gap and same
// total notional:
//
//   ONE swap    escrowed: 3840
//   EIGHT swaps escrowed: 1380      -> 36% of the single-swap charge
//
// A 64% discount for a two-line change to a searcher's bundle. The design asserted
// the opposite as settled fact and the planned test_SplittingGivesNoDiscount was never
// written.
//
// The rule these tests pin: the surcharge rate is fixed by maxAbsGap -- the widest the
// gap has been during its life -- so it is constant for the gap's whole life and N legs
// sum to what one leg of the same total notional pays.
//
// Measured after the fix, 500k close of a 972-tick gap:
//
//   legs   1    2    4    8   |  12    16    24    32    51
//   esc  2400 2400 2400 2400  | 2200  2250  2200  2175  2165
//
// Exact equality to 8 legs. Beyond that a residual appears which is NOT rate decay --
// the per-leg rate stays flat (test_RateDoesNotDecayAcrossTheClose). It is closure
// granularity: the gap shuts when |gap| falls to gapThresholdTicks, and finer legs
// cross that band precisely, leaving the remainder to trade uncharged, while a coarse
// final leg is charged in full as it crosses. The residual is therefore bounded by the
// sub-threshold band the hook is deliberately blind to and floors around
// 90%. Was 36% before the fix.
// ============================================================
contract SplittingTest is BackdraftTestBase {

    address constant LP    = address(0x1001);
    address constant ROHAN = address(0xaaaa);
    address constant VIK   = address(0xbbbb);

    int24 constant LO = -6000;
    int24 constant HI =  6000;

    // Total notional of the close, held constant across every split count.
    //
    // Sized to CLOSE the gap with minimal overshoot (measured: a 500k open produces a
    // 972-tick gap, which ~500k of opposing flow closes). This matters. If the close
    // is oversized, the single-swap case pays surcharge on the overshoot notional --
    // flow that is past the reference and therefore not arbitrage -- while a split
    // close simply stops being charged once the gap shuts. That asymmetry is the
    // single swap being OVERCHARGED, not the splitter getting a discount, and
    // test_OversizedSingleSwapOverpaysOnOvershoot below pins it explicitly.
    int256 constant CLOSE_TOTAL = 500_000e18;

    function setUp() public override {
        super.setUp();
        _fund(LP); _fund(ROHAN); _fund(VIK);
        _addLiquidity(LP, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
    }

    function _fund(address who) internal {
        token0.transfer(who, 50_000_000e18);
        token1.transfer(who, 50_000_000e18);
    }

    /// @dev Open a gap, then close it in `legs` equal pieces. Returns total escrowed.
    ///      Asserts its own preconditions rather than skipping.
    function _escrowAfterSplitClose(uint256 legs) internal returns (uint128) {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "precondition: gap must open");

        int256 per = CLOSE_TOTAL / int256(legs);
        for (uint256 i = 0; i < legs; i++) {
            _swap(VIK, true, -per);
        }
        return hook.gapAt(poolId, idx).escrowed;
    }

    // ------------------------------------------------------------------
    // The measurement
    // ------------------------------------------------------------------

    /// @notice Run the split curve and print it. This is an experiment first and an
    ///         assertion second: the numbers are logged so the curve can be read even
    ///         when the bound passes.
    function test_SplitCurveIsFlat() public {
        uint256[4] memory legs = [uint256(1), 2, 4, 8];
        uint128[4] memory escrowed;

        for (uint256 i = 0; i < legs.length; i++) {
            uint256 snap = vm.snapshotState();
            escrowed[i] = _escrowAfterSplitClose(legs[i]);
            console.log("legs:", legs[i], "escrowed:", escrowed[i]);
            vm.revertToState(snap);
        }

        // At these granularities every leg is charged, so totals must match exactly
        // up to integer division of the notional.
        for (uint256 i = 1; i < legs.length; i++) {
            assertApproxEqRel(
                uint256(escrowed[i]), uint256(escrowed[0]), 0.02e18,
                "split close collected a materially different total than one swap"
            );
        }
    }

    /// @notice At high leg counts a residual appears. It is closure granularity, not
    ///         rate decay, and it is bounded by the sub-threshold band. Pinned with a
    ///         floor so a regression to rate decay (which was unbounded, reaching 36%)
    ///         fails loudly.
    function test_HighGranularityResidualIsBounded() public {
        uint256 snap = vm.snapshotState();
        uint128 one = _escrowAfterSplitClose(1);
        vm.revertToState(snap);

        uint256[4] memory legs = [uint256(12), 16, 32, 51];
        for (uint256 i = 0; i < legs.length; i++) {
            uint256 s2 = vm.snapshotState();
            uint128 many = _escrowAfterSplitClose(legs[i]);
            console.log("legs:", legs[i], "escrowed:", many);
            assertGe(uint256(many) * 100, uint256(one) * 85,
                "residual exceeded the sub-threshold band: rate decay may have returned");
            vm.revertToState(s2);
        }
    }

    /// @notice The specific case from the bug report: eight legs vs one. On the
    ///         unpatched branch this ratio was 0.36.
    function test_EightLegsPaySameAsOne() public {
        uint256 snap = vm.snapshotState();
        uint128 one = _escrowAfterSplitClose(1);
        vm.revertToState(snap);
        uint128 eight = _escrowAfterSplitClose(8);

        assertApproxEqRel(uint256(eight), uint256(one), 0.02e18,
            "eight legs must pay what one leg pays");
    }

    /// @notice The rate is fixed by maxAbsGap, so it must not decay as the gap narrows.
    ///         Two identical-size legs at different points in the close must pay the
    ///         same surcharge.
    function test_RateDoesNotDecayAcrossTheClose() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "precondition: gap must open");

        uint128 e0 = hook.gapAt(poolId, idx).escrowed;
        _swap(VIK, true, -100_000e18);
        uint128 firstLeg = hook.gapAt(poolId, idx).escrowed - e0;

        uint128 e1 = hook.gapAt(poolId, idx).escrowed;
        _swap(VIK, true, -100_000e18);
        uint128 secondLeg = hook.gapAt(poolId, idx).escrowed - e1;

        assertGt(firstLeg, 0, "precondition: first leg must be surcharged");
        assertEq(secondLeg, firstLeg,
            "equal-notional legs must pay equally: rate must not decay with the gap");
    }

    /// @notice maxAbsGap must not move during a close, or the rate would decay again
    ///         by a different route.
    function test_MaxAbsGapConstantAcrossClose() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        uint24 peak = hook.gapAt(poolId, idx).maxAbsGap;

        _swap(VIK, true, -100_000e18);
        assertEq(hook.gapAt(poolId, idx).maxAbsGap, peak, "maxAbsGap moved during close");
        _swap(VIK, true, -100_000e18);
        assertEq(hook.gapAt(poolId, idx).maxAbsGap, peak, "maxAbsGap moved during close");
    }

    /// @notice A widener that pushes the gap wider raises the rate for everyone who
    ///         closes afterwards — maxAbsGap is a running peak, not a snapshot at open.
    function test_FurtherWideningRaisesTheRate() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        uint24 peakBefore = hook.gapAt(poolId, idx).maxAbsGap;

        _swap(ROHAN, false, -300_000e18);                 // widen further
        assertGt(hook.gapAt(poolId, idx).maxAbsGap, peakBefore, "peak must rise");

        uint128 e0 = hook.gapAt(poolId, idx).escrowed;
        _swap(VIK, true, -100_000e18);
        assertGt(hook.gapAt(poolId, idx).escrowed - e0, 0, "close must be surcharged");
    }

    /// @notice The residual asymmetry, stated rather than hidden. A single swap sized
    ///         well past what the gap needs pays surcharge on the overshoot too, so it
    ///         pays MORE than the same notional split into legs that stop once the gap
    ///         shuts. The direction matters: splitting never pays less per unit of gap
    ///         closed, it only avoids being charged for non-arbitrage flow.
    function test_OversizedSingleSwapOverpaysOnOvershoot() public {
        uint256 snap = vm.snapshotState();

        // One oversized swap: 800k against a gap that ~500k closes.
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        _swap(VIK, true, -800_000e18);
        uint128 single = hook.gapAt(poolId, idx).escrowed;

        vm.revertToState(snap);

        // Same 800k in eight legs: charged until the gap shuts, then not.
        _swap(ROHAN, false, -500_000e18);
        idx = hook.openGapIdx(poolId);
        for (uint256 i = 0; i < 8; i++) _swap(VIK, true, -100_000e18);
        uint128 split = hook.gapAt(poolId, idx).escrowed;

        assertGt(single, split,
            "oversized single swap should overpay relative to a split that stops at close");
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    /// @notice For any leg count, splitting must not buy a discount.
    function testFuzz_SplittingNeverDiscounts(uint8 legs) public {
        legs = uint8(bound(legs, 2, 64));

        uint256 snap = vm.snapshotState();
        uint128 one = _escrowAfterSplitClose(1);
        vm.revertToState(snap);
        uint128 many = _escrowAfterSplitClose(legs);

        // Floor at 85% of the single-swap total. Anything below that means the rate is
        // decaying again rather than the close simply stopping at the threshold.
        assertGe(uint256(many) * 100, uint256(one) * 85,
            "splitting bought a material discount at some leg count");
    }
}
