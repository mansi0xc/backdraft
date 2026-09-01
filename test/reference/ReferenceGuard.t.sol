// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test}              from "forge-std/Test.sol";
import {SplitV3Reference}  from "../../src/references/SplitV3Reference.sol";
import {MockV3Pool}        from "../mocks/MockV3Pool.sol";
import {PoolId}            from "v4-core/types/PoolId.sol";

// ============================================================
// Reference-price regression tests.
//
// Two defects, both invisible to a fork test against a healthy mainnet pool, which is
// why the existing fork tests never caught them:
//
// R1  _twapTick called observe() unguarded. A v3 pool REVERTS when the requested window
//     predates its oldest retained observation (insufficient observation cardinality).
//     That revert propagated getRefTick -> beforeSwap -> the swap itself, bricking every
//     trade in the pool. Appendix §7 specifies the failure mode as "Freeze — no credit,
//     no surcharge. An unreliable reference should produce inaction, not a wrong charge."
//     A reverted swap is not inaction. plan.md logged this as a High risk and it was
//     never handled.
//
// R2  The TWAP divided tickCumulative delta by the window with no floor adjustment.
//     Solidity truncates toward zero, so a negative delta that does not divide evenly
//     rounds UP and reports a tick one higher than the true average. Uniswap's own
//     OracleLibrary.consult applies exactly this correction.
// ============================================================
contract ReferenceGuardTest is Test {

    SplitV3Reference ref;
    MockV3Pool fast;
    MockV3Pool deep;
    PoolId constant ID = PoolId.wrap(bytes32(uint256(1)));

    uint32 constant WINDOW = 1800;
    uint24 constant MAX_DEV = 50;
    uint24 constant FREEZE_DEV = 250;   // 5x — the absurdity backstop, not the curve

    function setUp() public {
        ref  = new SplitV3Reference(address(this));
        fast = new MockV3Pool(1000);
        deep = new MockV3Pool(1000);

        // Deep pool's TWAP resolves to tick 1000: 1000 * 1800 seconds of accumulation.
        deep.setCumulatives(0, int56(int256(1000) * int256(uint256(WINDOW))));

        ref.setConfig(ID, SplitV3Reference.Config({
            fastPool:         address(fast),
            deepPool:         address(deep),
            twapWindow:        WINDOW,
            guardMaxDevTicks:  MAX_DEV,
            freezeMaxDevTicks: FREEZE_DEV,
            invertTicks:       false
        }));
    }

    // ------------------------------------------------------------------
    // R1 — freeze, never revert
    // ------------------------------------------------------------------

    /// @notice Baseline: healthy pools produce a usable reference.
    function test_HealthyPoolsReturnReference() public view {
        (int24 tick, bool ok,) = ref.getRefTick(ID);
        assertTrue(ok, "healthy pools must produce a reference");
        assertEq(tick, 1000, "reference must be the fast pool's spot tick");
    }

    /// @notice The headline: an observe() revert must FREEZE, not propagate. Before this
    ///         fix, this call reverted, and in production that revert would have taken
    ///         the entire swap with it.
    function test_ObserveRevertFreezesInsteadOfReverting() public {
        deep.setObserveReverts(true);

        (int24 tick, bool ok,) = ref.getRefTick(ID);
        assertFalse(ok, "insufficient cardinality must freeze the reference");
        assertEq(tick, 0, "frozen reference must return a zero tick");
    }

    /// @notice And it recovers once cardinality is increased — the freeze is a state,
    ///         not a permanent failure.
    function test_ReferenceRecoversAfterCardinalityIncrease() public {
        deep.setObserveReverts(true);
        (, bool frozen,) = ref.getRefTick(ID);
        assertFalse(frozen, "precondition: must be frozen");

        deep.setObserveReverts(false);
        (int24 tick, bool ok,) = ref.getRefTick(ID);
        assertTrue(ok, "reference must recover");
        assertEq(tick, 1000, "recovered reference must be correct");
    }

    /// @notice isReady() is the deployment prerequisite check: it must report false
    ///         while the deep pool cannot serve the guard window.
    function test_IsReadyReflectsObserveAvailability() public {
        assertTrue(ref.isReady(ID), "configured healthy pools must be ready");

        deep.setObserveReverts(true);
        assertFalse(ref.isReady(ID), "must not report ready when observe() fails");
    }

    function test_IsReadyFalseForUnconfiguredPool() public view {
        assertFalse(ref.isReady(PoolId.wrap(bytes32(uint256(99)))), "unconfigured pool");
    }

    // ------------------------------------------------------------------
    // R2 — TWAP floor rounding
    // ------------------------------------------------------------------

    /// @notice Negative delta that does not divide evenly must round DOWN.
    ///         delta = -1000*1800 - 1 = -1800001; -1800001 / 1800 truncates to -1000,
    ///         but the true average is -1000.00055…, so the correct tick is -1001.
    function test_NegativeTwapRoundsDown() public {
        fast.setTick(-1001);
        deep.setTick(-1001);
        deep.setCumulatives(0, -(int56(int256(1000) * int256(uint256(WINDOW))) + 1));

        (int24 tick, bool ok,) = ref.getRefTick(ID);
        assertTrue(ok, "guard must not freeze: spot -1001 vs floored TWAP -1001 agree");
        assertEq(tick, -1001, "reference tick");
    }

    /// @notice Without the floor adjustment the TWAP would read -1000 while spot is
    ///         -1051, reporting 51 ticks of divergence. With it the TWAP reads -1001 and
    ///         the divergence is exactly 50.
    ///
    ///         This assertion used to be on ok=true, because 51 tripped the old boolean
    ///         guard and 50 did not. Divergence no longer freezes, so ok=true would pass
    ///         either way and the test would silently stop testing the correction. It
    ///         now pins the reported divergence, which is what the multiplier consumes.
    function test_FloorAdjustmentDecidesDivergenceAtBoundary() public {
        fast.setTick(-1051);
        deep.setTick(-1051);
        deep.setCumulatives(0, -(int56(int256(1000) * int256(uint256(WINDOW))) + 1));

        (, bool ok, uint24 div) = ref.getRefTick(ID);
        assertTrue(ok, "must not freeze");
        assertEq(div, 50, "floor adjustment must make the divergence 50, not 51");
    }

    /// @notice Positive deltas are unaffected — truncation toward zero is already the
    ///         floor for positive numbers.
    function test_PositiveTwapUnaffectedByAdjustment() public {
        deep.setCumulatives(0, int56(int256(1000) * int256(uint256(WINDOW))) + 1);
        (int24 tick, bool ok,) = ref.getRefTick(ID);
        assertTrue(ok, "must not freeze");
        assertEq(tick, 1000, "positive delta rounding unchanged");
    }

    // ------------------------------------------------------------------
    // Guards still work
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // §10 — divergence is REPORTED, not switched on
    // ------------------------------------------------------------------

    /// @notice The §10 headline, at the reference layer. Divergence past the old guard
    ///         threshold used to return ok=false, which meant zero surcharge on every
    ///         gap of every size — an off-switch reachable for a measured $7-$21. It
    ///         must now keep reporting, and surface the divergence for the caller to
    ///         price.
    function test_DeepSpotVsTwapDivergenceReportsInsteadOfFreezing() public {
        deep.setTick(1000 + int24(int256(uint256(MAX_DEV))) + 1);
        (, bool ok, uint24 div) = ref.getRefTick(ID);
        assertTrue(ok, "deep-vs-TWAP divergence must NOT freeze");
        assertEq(div, MAX_DEV + 1, "divergence must be reported to the caller");
    }

    function test_FastVsDeepDivergenceReportsInsteadOfFreezing() public {
        fast.setTick(1000 + int24(int256(uint256(MAX_DEV))) + 1);
        (, bool ok, uint24 div) = ref.getRefTick(ID);
        assertTrue(ok, "fast-vs-deep divergence must NOT freeze");
        assertEq(div, MAX_DEV + 1, "divergence must be reported to the caller");
    }

    /// @notice Divergence is the MAX of the two signals, so an attacker cannot halve
    ///         the reported number by splitting the push across both sources.
    function test_DivergenceTakesTheWorseOfBothSignals() public {
        fast.setTick(1000 + 30);   // fast vs deep = 30
        deep.setTick(1000 + 70);   // deep vs TWAP = 70, fast vs deep = 40
        (, bool ok, uint24 div) = ref.getRefTick(ID);
        assertTrue(ok, "must not freeze");
        assertEq(div, 70, "must report the larger of the two divergence signals");
    }

    /// @notice Agreement reports zero divergence — the curve stays at 1.00x in normal
    ///         operation, so honest flow is not taxed by this change.
    function test_AgreeingSourcesReportZeroDivergence() public view {
        (, bool ok, uint24 div) = ref.getRefTick(ID);
        assertTrue(ok, "must not freeze");
        assertEq(div, 0, "agreeing sources must report zero divergence");
    }

    /// @notice The absurdity backstop still exists and is deliberately far out. This
    ///         is a bounded off-switch, not an eliminated one: §10's argument applies
    ///         to any freeze condition, and the honest claim is that reaching this one
    ///         costs ~5x the $21 baseline, not that it is unreachable.
    function test_FreezeBackstopStillFiresAtAbsurdDivergence() public {
        fast.setTick(1000 + int24(int256(uint256(FREEZE_DEV))) + 1);
        (, bool ok, uint24 div) = ref.getRefTick(ID);
        assertFalse(ok, "divergence past the backstop must freeze");
        assertEq(div, FREEZE_DEV + 1, "divergence reported even when frozen");
    }

    /// @notice Exactly at the backstop must NOT freeze — strictly greater, as before.
    function test_ExactlyAtBackstopDoesNotFreeze() public {
        fast.setTick(1000 + int24(int256(uint256(FREEZE_DEV))));
        (, bool ok,) = ref.getRefTick(ID);
        assertTrue(ok, "divergence exactly at the backstop must not freeze");
    }

    /// @notice freezeMaxDevTicks = 0 disables freezing on divergence entirely — the
    ///         configuration §10 actually recommends once truncation lands.
    function test_ZeroBackstopNeverFreezesOnDivergence() public {
        ref.setConfig(ID, SplitV3Reference.Config({
            fastPool:          address(fast),
            deepPool:          address(deep),
            twapWindow:        WINDOW,
            guardMaxDevTicks:  MAX_DEV,
            freezeMaxDevTicks: 0,
            invertTicks:       false
        }));
        fast.setTick(500_000);
        (, bool ok, uint24 div) = ref.getRefTick(ID);
        assertTrue(ok, "backstop disabled: must never freeze on divergence");
        assertGt(div, FREEZE_DEV, "and must still report the divergence");
    }

    /// @notice A backstop at or below the 1.00x tolerance would freeze before the curve
    ///         engages, restoring the cheap off-switch. Rejected at config time.
    function test_SetConfigRejectsBackstopBelowGuard() public {
        vm.expectRevert(bytes("freeze <= guard"));
        ref.setConfig(ID, SplitV3Reference.Config({
            fastPool:          address(fast),
            deepPool:          address(deep),
            twapWindow:        WINDOW,
            guardMaxDevTicks:  MAX_DEV,
            freezeMaxDevTicks: MAX_DEV,
            invertTicks:       false
        }));
    }

    function test_UnconfiguredPoolFreezes() public view {
        (, bool ok,) = ref.getRefTick(PoolId.wrap(bytes32(uint256(99))));
        assertFalse(ok, "unconfigured pool must freeze, not revert");
    }

    /// @notice invertTicks negates the reference (v3 token ordering differs from v4).
    function test_InvertTicksNegatesReference() public {
        ref.setConfig(ID, SplitV3Reference.Config({
            fastPool:         address(fast),
            deepPool:         address(deep),
            twapWindow:        WINDOW,
            guardMaxDevTicks:  MAX_DEV,
            freezeMaxDevTicks: FREEZE_DEV,
            invertTicks:       true
        }));
        (int24 tick, bool ok,) = ref.getRefTick(ID);
        assertTrue(ok, "must not freeze");
        assertEq(tick, -1000, "inverted reference must be negated");
    }

    /// @notice Fuzz: getRefTick must never revert, whatever the pools report. Freezing
    ///         is always available as an answer; reverting is not.
    function testFuzz_GetRefTickNeverReverts(int24 fastTick, int24 deepTick, bool breakObserve)
        public
    {
        fastTick = int24(bound(int256(fastTick), -800_000, 800_000));
        deepTick = int24(bound(int256(deepTick), -800_000, 800_000));

        fast.setTick(fastTick);
        deep.setTick(deepTick);
        deep.setObserveReverts(breakObserve);

        try ref.getRefTick(ID) returns (int24, bool, uint24) {
            // Any answer is acceptable; reverting is not.
        } catch {
            fail();
        }
    }
}
