// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BackdraftTestBase} from "../BackdraftTestBase.sol";
import {DivergenceMath}    from "../../src/libraries/DivergenceMath.sol";

// ============================================================
// Graduated divergence fee — appendix §10.
//
// The design this replaces: when the two reference sources disagreed by more than
// guardMaxDevTicks, getRefTick returned ok=false and beforeSwap returned early. Freezing
// means zero surcharge on every gap of every size, so the freeze condition was an
// off-switch that anyone could reach for a measured $7-$21 — shove the thin 0.01% pool
// one tick past the tolerance and the mechanism stops. §10 further showed the tolerance
// could not be tuned out of the problem, because the same number governed two attacks:
// lowering it made the freeze cheaper to trigger, raising it widened the budget for
// masking a gap underneath it. No setting closed both.
//
// The replacement has no state to aim at. Divergence is reported and PRICED: flat below
// the tolerance, rising linearly above it, bounded by a ceiling. Every additional tick
// of manipulation makes the arbitrage the manipulator is protecting more expensive.
//
// The property these tests exist to pin, above all others:
//
//     NO AMOUNT OF DIVERGENCE PRODUCES A ZERO SURCHARGE.
//
// Everything else here is shape (flat region, slope, ceiling, monotonicity). That one
// is the security claim.
// ============================================================
contract GraduatedFeeTest is BackdraftTestBase {

    address constant LP     = address(0x1001);
    address constant ROHAN  = address(0xaaaa);   // widener / originator
    address constant VIK    = address(0xbbbb);   // arbitrageur / closer

    int24 constant LO = -6000;
    int24 constant HI =  6000;

    uint24 constant GUARD = 50;      // matches BackdraftTestBase's guardMaxDevTicks

    function setUp() public override {
        // Engage the curve: +1% surcharge per tick of excess divergence, ceiling 5.00x.
        divSlopeBps   = 100;
        maxDivMultBps = 50_000;

        super.setUp();
        _fund(LP); _fund(ROHAN); _fund(VIK);
        _addLiquidity(LP, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
    }

    function _fund(address who) internal {
        token0.transfer(who, 50_000_000e18);
        token1.transfer(who, 50_000_000e18);
    }

    /// @dev Open a gap with a widening swap, set the divergence the reference reports,
    ///      then close it and return the surcharge collected on the closing swap.
    ///      Escrow accumulated by the opening swap is zero (wideners are not surcharged),
    ///      so the gap's escrow after the close IS the closing surcharge.
    function _surchargeAtDivergence(uint24 divTicks) internal returns (uint128) {
        uint256 snap = vm.snapshotState();

        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        require(idx != 0, "precondition: gap must open");

        oracle.setDivergence(poolId, divTicks);
        _swap(VIK, true, -200_000e18);

        uint128 escrowed = hook.gapAt(poolId, idx).escrowed;

        vm.revertToState(snap);
        return escrowed;
    }

    // ------------------------------------------------------------------
    // The security claim
    // ------------------------------------------------------------------

    /// @notice THE headline test. At the divergence that used to freeze the hook — and
    ///         far past it — a closing swap must still be surcharged. This is the $21
    ///         off-switch, asserted absent.
    function test_DivergencePastOldFreezePointStillSurcharges() public {
        assertGt(_surchargeAtDivergence(GUARD + 1), 0,
            "one tick past the old guard must not disable capture");
        assertGt(_surchargeAtDivergence(GUARD * 10), 0,
            "10x the old guard must not disable capture");
        assertGt(_surchargeAtDivergence(type(uint24).max), 0,
            "no divergence value may produce a zero surcharge");
    }

    /// @notice And the manipulation is not merely survivable, it is counterproductive:
    ///         pushing the reference costs the pusher more, not less.
    function test_ManipulationRaisesTheCostOfTheArbitrageItProtects() public {
        uint128 honest    = _surchargeAtDivergence(0);
        uint128 pushed    = _surchargeAtDivergence(GUARD + 50);
        assertGt(pushed, honest, "divergence must raise the surcharge, never lower it");
    }

    /// @notice Regression for an arithmetic reintroduction of the off-switch. The
    ///         multiplier result is a uint256 clamped into a uint128 escrow. Clamping
    ///         only to the notional (itself a uint256) and casting would truncate for
    ///         large swaps, and truncating a value just above 2^128 yields a NEAR-ZERO
    ///         surcharge — the exact outcome the curve exists to make unreachable.
    ///         Saturating at uint128 max is what keeps the claim true at every size.
    function test_LargeNotionalDoesNotTruncateSurchargeToZero() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        require(idx != 0, "precondition: gap must open");

        oracle.setDivergence(poolId, GUARD + 400);   // ceiling multiplier, 5.00x
        _swap(VIK, true, -400_000e18);

        assertGt(hook.gapAt(poolId, idx).escrowed, 0,
            "a large closing swap at max multiplier must still be surcharged");
    }

    // ------------------------------------------------------------------
    // Shape: flat, then linear, then capped
    // ------------------------------------------------------------------

    /// @notice Honest operation is untaxed. Fast and deep normally disagree by a few
    ///         ticks; that must not change anyone's fee.
    function test_FlatRegionLeavesSurchargeUnchanged() public {
        uint128 base = _surchargeAtDivergence(0);
        assertGt(base, 0, "precondition: baseline surcharge must be non-zero");

        assertEq(_surchargeAtDivergence(1),     base, "1 tick of divergence: unchanged");
        assertEq(_surchargeAtDivergence(GUARD), base, "exactly at tolerance: unchanged");
    }

    /// @notice One tick past the tolerance engages the curve — the boundary is strictly
    ///         greater, matching the guard it replaces.
    function test_CurveEngagesOneTickPastTolerance() public {
        assertGt(_surchargeAtDivergence(GUARD + 1), _surchargeAtDivergence(GUARD),
            "the curve must engage above the tolerance, not at it");
    }

    /// @notice The ceiling binds: beyond it, more divergence stops buying more surcharge.
    ///         maxDivMultBps = 50_000 is 5.00x, reached at 400 ticks of excess.
    function test_CeilingBindsAndHolds() public {
        uint128 atCeiling  = _surchargeAtDivergence(GUARD + 400);
        uint128 pastIt     = _surchargeAtDivergence(GUARD + 4000);
        assertEq(pastIt, atCeiling, "surcharge must not grow past the configured ceiling");
    }

    // ------------------------------------------------------------------
    // DivergenceMath unit tests
    // ------------------------------------------------------------------

    function test_MultiplierFlatBelowAndAtTolerance() public pure {
        assertEq(DivergenceMath.multiplierBps(0,  50, 100, 50_000), 10_000);
        assertEq(DivergenceMath.multiplierBps(49, 50, 100, 50_000), 10_000);
        assertEq(DivergenceMath.multiplierBps(50, 50, 100, 50_000), 10_000);
    }

    function test_MultiplierLinearAboveTolerance() public pure {
        // 1 tick excess at 100 bps/tick = 1.01x
        assertEq(DivergenceMath.multiplierBps(51,  50, 100, 50_000), 10_100);
        // 50 ticks excess = 1.50x
        assertEq(DivergenceMath.multiplierBps(100, 50, 100, 50_000), 15_000);
    }

    function test_MultiplierRespectsCeiling() public pure {
        assertEq(DivergenceMath.multiplierBps(10_000, 50, 100, 50_000), 50_000);
    }

    /// @notice Zero slope disables the curve without disabling the hook — the neutral
    ///         configuration every pre-existing test runs under.
    function test_ZeroSlopeIsNeutralNotDisabling() public pure {
        assertEq(DivergenceMath.multiplierBps(10_000, 50, 0, 50_000), 10_000,
            "zero slope must return 1.00x, never zero");
    }

    /// @notice A ceiling below 1.00x is a misconfiguration that would let a manipulator
    ///         REDUCE the surcharge by pushing harder — reintroducing the off-switch
    ///         through the config surface. It is floored, not honoured.
    function test_CeilingBelowOneIsFlooredNotHonoured() public pure {
        assertEq(DivergenceMath.multiplierBps(10_000, 50, 100, 5_000), 10_000,
            "a sub-1.00x ceiling must be raised to 1.00x");
        assertEq(DivergenceMath.multiplierBps(10_000, 50, 100, 0), 10_000,
            "a zero ceiling must be raised to 1.00x");
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    /// @notice Monotone non-decreasing in divergence, and never below 1.00x. Together
    ///         these are the formal statement of "manipulation can only cost you more".
    function testFuzz_MultiplierMonotoneAndNeverBelowOne(
        uint24 divA, uint24 divB, uint24 flat, uint16 slope, uint16 ceiling
    ) public pure {
        if (divA > divB) (divA, divB) = (divB, divA);

        uint256 mA = DivergenceMath.multiplierBps(divA, flat, slope, ceiling);
        uint256 mB = DivergenceMath.multiplierBps(divB, flat, slope, ceiling);

        assertGe(mA, DivergenceMath.ONE, "multiplier must never fall below 1.00x");
        assertLe(mA, mB, "multiplier must be non-decreasing in divergence");
    }

    /// @notice The end-to-end version of the same claim, through the real swap path:
    ///         whatever divergence the reference reports, a closing swap is surcharged.
    function testFuzz_SurchargeNeverZeroAtAnyDivergence(uint24 divTicks) public {
        assertGt(_surchargeAtDivergence(divTicks), 0,
            "no divergence value may produce a zero surcharge");
    }

    /// @notice Escrow can never exceed the swapper's input — the multiplier is clamped
    ///         at the notional, so an aggressive ceiling cannot mint value out of a
    ///         swap that is not there.
    function testFuzz_SurchargeNeverExceedsNotional(uint24 divTicks) public {
        uint128 s = _surchargeAtDivergence(divTicks);
        assertLe(uint256(s), 200_000e18, "surcharge must never exceed the swap notional");
    }
}
