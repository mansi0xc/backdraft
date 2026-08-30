// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console}   from "forge-std/Test.sol";
import {SurchargeMath}   from "../../src/libraries/SurchargeMath.sol";

// ============================================================
// Surcharge precision.
//
// The old implementation collapsed the rate to an integer number of basis points BEFORE
// applying it to the notional:
//
//     bps = gapTicks * rateBps / 10_000;      // integer division
//     return notional * bps / 10_000;
//
// A step function where the design assumes a slope, landing hardest at exactly the gaps
// the hook exists to price. With captureRateBps = 100, nothing at all is collected until
// the gap reaches 100 ticks — above gapThresholdTicks = 65, so the hook opens gaps,
// escrows nothing, and settles empty pots.
//
// The existing SurchargeMath tests all pass against BOTH implementations, and so does
// the whole 132-test suite: the harness uses captureRateBps = 500 with scenarios large
// enough to bind the cap, which is the one region where the two agree. That is why this
// survived six reviews.
// ============================================================
contract SurchargePrecisionTest is Test {

    uint256 constant N = 1e18;

    // ------------------------------------------------------------------
    // The bug
    // ------------------------------------------------------------------

    /// @notice The headline: a gap above the 65-tick threshold at a plausible production
    ///         rate must collect something. Old implementation returned exactly 0.
    function test_GapAboveThresholdIsNeverFree() public pure {
        assertGt(SurchargeMath.compute(N, 66, 100, 200), 0, "66-tick gap collected nothing");
        assertGt(SurchargeMath.compute(N, 70, 100, 200), 0, "70-tick gap collected nothing");
        assertGt(SurchargeMath.compute(N, 99, 100, 200), 0, "99-tick gap collected nothing");
    }

    /// @notice Distinct gaps must produce distinct surcharges. Under the old truncation
    ///         every gap from 60 to 79 collected identically at rate 500.
    function test_DistinctGapsPriceDistinctly() public pure {
        uint128 g60 = SurchargeMath.compute(N, 60, 500, 10_000);
        uint128 g65 = SurchargeMath.compute(N, 65, 500, 10_000);
        uint128 g79 = SurchargeMath.compute(N, 79, 500, 10_000);

        assertGt(g65, g60, "65 must cost more than 60");
        assertGt(g79, g65, "79 must cost more than 65");
    }

    /// @notice Doubling the gap must roughly double the surcharge. Old behaviour: gap
    ///         100 and gap 150 at rate 100 collected the SAME amount.
    function test_SurchargeScalesWithGap() public pure {
        uint128 g100 = SurchargeMath.compute(N, 100, 100, 10_000);
        uint128 g150 = SurchargeMath.compute(N, 150, 100, 10_000);
        uint128 g200 = SurchargeMath.compute(N, 200, 100, 10_000);

        assertApproxEqRel(uint256(g150), uint256(g100) * 3 / 2, 0.01e18, "150 vs 100");
        assertApproxEqRel(uint256(g200), uint256(g100) * 2,     0.01e18, "200 vs 100");
    }

    /// @notice Exact expected values, so a future refactor cannot drift the formula.
    ///         surcharge = notional * gap * rate / 1e8
    function test_ExactValues() public pure {
        assertEq(SurchargeMath.compute(N,  66, 100, 10_000),  66_000_000_000_000, "66@100");
        assertEq(SurchargeMath.compute(N,  99, 100, 10_000),  99_000_000_000_000, "99@100");
        assertEq(SurchargeMath.compute(N,  65, 500, 10_000), 325_000_000_000_000, "65@500");
        assertEq(SurchargeMath.compute(N,  79, 500, 10_000), 395_000_000_000_000, "79@500");
    }

    // ------------------------------------------------------------------
    // The cap still binds
    // ------------------------------------------------------------------

    function test_CapBindsAtLargeGaps() public pure {
        // 3000 ticks at rate 500 = 150 bps uncapped; cap of 100 bps must win.
        uint128 capped = SurchargeMath.compute(N, 3000, 500, 100);
        assertEq(capped, N * 100 / 10_000, "cap must bind");
    }

    function test_CapDoesNotBindBelowIt() public pure {
        uint128 s = SurchargeMath.compute(N, 100, 100, 200);
        assertEq(s, 100_000_000_000_000, "cap must not bind at 10 bps under a 200 bp cap");
    }

    // ------------------------------------------------------------------
    // Degenerate inputs
    // ------------------------------------------------------------------

    function test_ZeroInputsReturnZero() public pure {
        assertEq(SurchargeMath.compute(0, 100, 500, 200), 0, "zero notional");
        assertEq(SurchargeMath.compute(N,   0, 500, 200), 0, "zero gap");
        assertEq(SurchargeMath.compute(N, 100,   0, 200), 0, "zero rate");
        assertEq(SurchargeMath.compute(N, 100, 500,   0), 0, "zero cap");
    }

    /// @notice Very small notionals still round toward zero — unavoidable in integer
    ///         arithmetic, and pinned so the behaviour is known rather than assumed.
    function test_DustNotionalRoundsToZero() public pure {
        assertEq(SurchargeMath.compute(1, 66, 100, 200), 0, "1 wei of notional");
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    /// @notice Monotonic in gap: a wider gap can never cost less.
    function testFuzz_MonotonicInGap(uint96 notional, uint24 gapA, uint24 gapB) public pure {
        notional = uint96(bound(notional, 1e12, type(uint96).max));
        gapA = uint24(bound(gapA, 1, 500_000));
        gapB = uint24(bound(gapB, 1, 500_000));
        if (gapA > gapB) (gapA, gapB) = (gapB, gapA);

        assertLe(
            SurchargeMath.compute(notional, gapA, 500, 10_000),
            SurchargeMath.compute(notional, gapB, 500, 10_000),
            "a wider gap cost less"
        );
    }

    /// @notice Never exceeds the cap, whatever the inputs.
    function testFuzz_NeverExceedsCap(uint96 notional, uint24 gap, uint16 rate, uint16 cap)
        public
        pure
    {
        notional = uint96(bound(notional, 0, type(uint96).max));
        cap      = uint16(bound(cap, 0, 10_000));

        uint128 s = SurchargeMath.compute(notional, gap, rate, cap);
        assertLe(uint256(s), uint256(notional) * cap / 10_000 + 1, "exceeded the cap");
        assertLe(uint256(s), uint256(notional), "exceeded the notional");
    }

    /// @notice Splitting a notional across N legs at a fixed rate collects the same
    ///         total, up to integer division. This is the property the whole
    ///         splitting-resistance fix rests on, verified at the arithmetic level
    ///         rather than only end-to-end.
    function testFuzz_AdditiveAcrossSplits(uint96 notional, uint8 legs) public pure {
        notional = uint96(bound(notional, 1e15, type(uint96).max));
        legs     = uint8(bound(legs, 2, 32));

        uint128 whole = SurchargeMath.compute(notional, 300, 500, 10_000);

        uint256 per = uint256(notional) / legs;
        uint256 sum;
        for (uint256 i = 0; i < legs; i++) {
            sum += SurchargeMath.compute(per, 300, 500, 10_000);
        }

        // Tolerance covers per-leg truncation of the notional only.
        assertApproxEqRel(sum, uint256(whole), 0.001e18, "splitting changed the total");
    }
}
