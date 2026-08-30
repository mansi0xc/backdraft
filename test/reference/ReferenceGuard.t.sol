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

    function setUp() public {
        ref  = new SplitV3Reference(address(this));
        fast = new MockV3Pool(1000);
        deep = new MockV3Pool(1000);

        // Deep pool's TWAP resolves to tick 1000: 1000 * 1800 seconds of accumulation.
        deep.setCumulatives(0, int56(int256(1000) * int256(uint256(WINDOW))));

        ref.setConfig(ID, SplitV3Reference.Config({
            fastPool:         address(fast),
            deepPool:         address(deep),
            twapWindow:       WINDOW,
            guardMaxDevTicks: MAX_DEV,
            invertTicks:      false
        }));
    }

    // ------------------------------------------------------------------
    // R1 — freeze, never revert
    // ------------------------------------------------------------------

    /// @notice Baseline: healthy pools produce a usable reference.
    function test_HealthyPoolsReturnReference() public view {
        (int24 tick, bool ok) = ref.getRefTick(ID);
        assertTrue(ok, "healthy pools must produce a reference");
        assertEq(tick, 1000, "reference must be the fast pool's spot tick");
    }

    /// @notice The headline: an observe() revert must FREEZE, not propagate. Before this
    ///         fix, this call reverted, and in production that revert would have taken
    ///         the entire swap with it.
    function test_ObserveRevertFreezesInsteadOfReverting() public {
        deep.setObserveReverts(true);

        (int24 tick, bool ok) = ref.getRefTick(ID);
        assertFalse(ok, "insufficient cardinality must freeze the reference");
        assertEq(tick, 0, "frozen reference must return a zero tick");
    }

    /// @notice And it recovers once cardinality is increased — the freeze is a state,
    ///         not a permanent failure.
    function test_ReferenceRecoversAfterCardinalityIncrease() public {
        deep.setObserveReverts(true);
        (, bool frozen) = ref.getRefTick(ID);
        assertFalse(frozen, "precondition: must be frozen");

        deep.setObserveReverts(false);
        (int24 tick, bool ok) = ref.getRefTick(ID);
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

        (int24 tick, bool ok) = ref.getRefTick(ID);
        assertTrue(ok, "guard must not freeze: spot -1001 vs floored TWAP -1001 agree");
        assertEq(tick, -1001, "reference tick");
    }

    /// @notice Without the floor adjustment the TWAP would read -1000 while spot is
    ///         -1051, a 51-tick divergence that trips a 50-tick guard. With it the TWAP
    ///         reads -1001 and the divergence is 50, which does not. This pins the
    ///         correction at the exact boundary where it changes behaviour.
    function test_FloorAdjustmentDecidesGuardAtBoundary() public {
        fast.setTick(-1051);
        deep.setTick(-1051);
        deep.setCumulatives(0, -(int56(int256(1000) * int256(uint256(WINDOW))) + 1));

        (, bool ok) = ref.getRefTick(ID);
        assertTrue(ok, "with floor adjustment the divergence is exactly 50, not 51");
    }

    /// @notice Positive deltas are unaffected — truncation toward zero is already the
    ///         floor for positive numbers.
    function test_PositiveTwapUnaffectedByAdjustment() public {
        deep.setCumulatives(0, int56(int256(1000) * int256(uint256(WINDOW))) + 1);
        (int24 tick, bool ok) = ref.getRefTick(ID);
        assertTrue(ok, "must not freeze");
        assertEq(tick, 1000, "positive delta rounding unchanged");
    }

    // ------------------------------------------------------------------
    // Guards still work
    // ------------------------------------------------------------------

    /// @notice Guard 1: deep spot diverging from its own TWAP freezes.
    function test_DeepSpotVsTwapDivergenceFreezes() public {
        deep.setTick(1000 + int24(int256(uint256(MAX_DEV))) + 1);
        (, bool ok) = ref.getRefTick(ID);
        assertFalse(ok, "deep spot vs TWAP divergence must freeze");
    }

    /// @notice Guard 2: fast diverging from deep freezes.
    function test_FastVsDeepDivergenceFreezes() public {
        fast.setTick(1000 + int24(int256(uint256(MAX_DEV))) + 1);
        (, bool ok) = ref.getRefTick(ID);
        assertFalse(ok, "fast vs deep divergence must freeze");
    }

    /// @notice Exactly at the threshold must NOT freeze — the guard is strictly greater.
    function test_ExactlyAtThresholdDoesNotFreeze() public {
        fast.setTick(1000 + int24(int256(uint256(MAX_DEV))));
        (, bool ok) = ref.getRefTick(ID);
        assertTrue(ok, "divergence exactly at the threshold must not freeze");
    }

    function test_UnconfiguredPoolFreezes() public view {
        (, bool ok) = ref.getRefTick(PoolId.wrap(bytes32(uint256(99))));
        assertFalse(ok, "unconfigured pool must freeze, not revert");
    }

    /// @notice invertTicks negates the reference (v3 token ordering differs from v4).
    function test_InvertTicksNegatesReference() public {
        ref.setConfig(ID, SplitV3Reference.Config({
            fastPool:         address(fast),
            deepPool:         address(deep),
            twapWindow:       WINDOW,
            guardMaxDevTicks: MAX_DEV,
            invertTicks:      true
        }));
        (int24 tick, bool ok) = ref.getRefTick(ID);
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

        try ref.getRefTick(ID) returns (int24, bool) {
            // Any answer is acceptable; reverting is not.
        } catch {
            fail();
        }
    }
}
