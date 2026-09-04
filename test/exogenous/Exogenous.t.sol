// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BackdraftTestBase} from "../BackdraftTestBase.sol";
import {BackdraftHook}     from "../../src/BackdraftHook.sol";

// ============================================================
// Exogenous capture regression tests.
//
// History: gap detection lived only in afterSwap. On the pure exogenous path —
// external market moves, nobody trades this pool, an arbitrageur arrives and closes
// the whole gap in one swap — beforeSwap returned early (no gap open, no surcharge),
// and by the time afterSwap ran the pool was already corrected, so no gap opened
// either. Measured on the unpatched branch:
//
//   openGapIdx before arb: 0
//   openGapIdx after arb:  1        (opened too late, on the residual)
//   escrow c0 gained:      0
//   escrow c1 gained:      0
//
// Zero captured. "Backdraft handles exogenous LVR too" was the project's main
// differentiator over Detox / WTH / ArbHook and it did not hold.
//
// The rule these tests pin — structural, not heuristic:
//
//   gap present at swap ENTRY                  -> pre-existing -> open in beforeSwap
//   gap absent at entry, present at EXIT       -> this swap caused it -> open in afterSwap
//
// The observable that distinguishes them is Gap.tickAtOpen: a gap opened in beforeSwap
// records the PRE-swap tick, one opened in afterSwap records the POST-swap tick.
// ============================================================
contract ExogenousTest is BackdraftTestBase {

    address constant LP    = address(0x1001);
    address constant ROHAN = address(0xaaaa);
    address constant VIK   = address(0xbbbb);

    int24 constant LO = -6000;
    int24 constant HI =  6000;

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

    function _contrib(uint256 idx, address who) internal view returns (uint128) {
        return hook.contribution(keccak256(abi.encode(poolId, idx, who)));
    }

    // ------------------------------------------------------------------
    // The headline: a single-swap close of a stale pool IS surcharged
    // ------------------------------------------------------------------

    /// @notice External market moves, this pool sits stale, arbitrageur closes the
    ///         whole gap in ONE swap. That swap must pay a surcharge. Before this
    ///         fix it paid nothing.
    function test_PureExogenous_SingleSwapClose_IsSurcharged() public {
        oracle.setRef(poolId, 200);                     // market moves, pool stale at ~0
        assertEq(hook.openGapIdx(poolId), 0, "precondition: no gap tracked yet");

        uint256 c0Before = _hookBalance(poolKey.currency0);
        uint256 c1Before = _hookBalance(poolKey.currency1);

        _swap(VIK, false, -300_000e18);                 // one swap, closes the gap

        uint256 captured = (_hookBalance(poolKey.currency0) - c0Before)
                         + (_hookBalance(poolKey.currency1) - c1Before);
        assertGt(captured, 0, "single-swap close of a stale pool must be surcharged");
    }

    /// @notice The gap must open on the PRE-swap tick — proof it was detected in
    ///         beforeSwap rather than after the arbitrage had already corrected it.
    function test_ExogenousGapOpensOnPreSwapTick() public {
        oracle.setRef(poolId, 200);
        int24 tickBefore = _poolTick();

        uint256 idx = hook.gaps(poolId).length;   // the gap beforeSwap will push
        _swap(VIK, false, -300_000e18);

        assertGt(idx, 0, "a gap must have been recorded");
        assertEq(hook.gapAt(poolId, idx).tickAtOpen, tickBefore,
            "exogenous gap must open on the pre-swap tick");
    }

    /// @notice Contrast case: a gap this swap created must still open in afterSwap,
    ///         on the POST-swap tick, and credit its originator. The two paths must
    ///         not collapse into one.
    function test_EndogenousGapStillOpensOnPostSwapTick() public {
        int24 tickBefore = _poolTick();                 // no oracle move: pool is fresh

        _swap(ROHAN, false, -500_000e18);

        uint256 idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "endogenous gap must open");
        assertTrue(hook.gapAt(poolId, idx).tickAtOpen != tickBefore,
            "endogenous gap must open on the post-swap tick");
        assertGt(_contrib(idx, ROHAN), 0, "originator must still be credited");
    }

    // ------------------------------------------------------------------
    // ... and all of it goes to LPs
    // ------------------------------------------------------------------

    /// @notice Empty ledger at settlement means the pool went stale from an external
    ///         move, so LPs — who bore the loss — receive the whole capture.
    function test_PureExogenous_EmptyLedger_AllToLps() public {
        oracle.setRef(poolId, 200);
        uint256 idx = hook.gaps(poolId).length;   // the gap beforeSwap will push
        _swap(VIK, false, -300_000e18);

        BackdraftHook.Gap memory g = hook.gapAt(poolId, idx);

        assertGt(g.escrowed, 0, "precondition: something was captured");
        assertEq(g.totalContribution, 0, "nothing in this pool widened the gap");

        if (!g.settled) hook.settle(poolId, idx);

        uint256 before = token0.balanceOf(LP) + token1.balanceOf(LP);
        vm.prank(LP, LP);
        hook.claimLp(poolId, idx, LO, HI, bytes32(0));
        uint256 gained = (token0.balanceOf(LP) + token1.balanceOf(LP)) - before;

        assertGt(gained, 0, "LP must receive the exogenous capture");
        // Sole eligible LP with an empty ledger: the whole pot, modulo integer division.
        assertApproxEqAbs(gained, uint256(g.escrowed), 2, "LPs must receive ~100% of escrow");
    }

    /// @notice The arbitrageur cannot claim any of what it paid on an exogenous gap.
    function test_PureExogenous_ArbitrageurClaimsNothing() public {
        oracle.setRef(poolId, 200);
        uint256 idx = hook.gaps(poolId).length;   // the gap beforeSwap will push
        _swap(VIK, false, -300_000e18);

        if (!hook.gapAt(poolId, idx).settled) hook.settle(poolId, idx);

        assertEq(_contrib(idx, VIK), 0, "corrector must hold no ledger credit");

        // Reverts with "n/a" rather than "nothing": on an exogenous gap the ledger is
        // empty, so there is no trader pot at all — a stronger statement than "this
        // particular caller has no credit in it".
        vm.prank(VIK, VIK);
        vm.expectRevert(BackdraftHook.NotApplicable.selector);
        hook.claimTrader(poolId, idx);
    }

    // ------------------------------------------------------------------
    // Mixed and negative cases
    // ------------------------------------------------------------------

    /// @notice A gap that is part external and part trader-caused splits by the share
    ///         the ledger explains — no extra branch, just `explained < 1`.
    function test_MixedGap_ExternalPortionStaysWithLps() public {
        oracle.setRef(poolId, 200);                     // ~200 ticks from outside

        _swap(ROHAN, true, -400_000e18);                // widens it further (endogenous)

        uint256 idx = hook.gaps(poolId).length - 1;
        BackdraftHook.Gap memory g = hook.gapAt(poolId, idx);

        assertGt(g.totalContribution, 0, "trader's widening must be credited");
        assertLt(g.totalContribution, g.maxAbsGap,
            "the externally-caused portion must remain unexplained");
    }

    /// @notice A pre-existing gap BELOW threshold must not open one. The hook is
    ///         deliberately blind under gapThresholdTicks (measurement noise, §4.5).
    function test_SubThresholdPreExistingGapDoesNotOpen() public {
        oracle.setRef(poolId, int24(int256(uint256(gapThresholdTicks)) - 5));

        uint256 c0Before = _hookBalance(poolKey.currency0);
        uint256 c1Before = _hookBalance(poolKey.currency1);

        _swap(VIK, false, -1_000e18);                   // tiny swap, stays sub-threshold

        assertEq(hook.openGapIdx(poolId), 0, "sub-threshold gap must not open");
        assertEq(_hookBalance(poolKey.currency0), c0Before, "no currency0 surcharge");
        assertEq(_hookBalance(poolKey.currency1), c1Before, "no currency1 surcharge");
    }

    /// @notice A frozen reference must produce inaction, not a wrong charge (§6).
    ///         An exogenous gap must NOT be opened while the guard is engaged.
    function test_FrozenOracleDoesNotOpenExogenousGap() public {
        oracle.setRef(poolId, 200);
        oracle.setFrozen(poolId, true);                  // guard engaged

        uint256 c0Before = _hookBalance(poolKey.currency0);
        uint256 c1Before = _hookBalance(poolKey.currency1);

        _swap(VIK, false, -300_000e18);

        assertEq(hook.openGapIdx(poolId), 0, "frozen reference must not open a gap");
        assertEq(_hookBalance(poolKey.currency0), c0Before, "frozen: no currency0 surcharge");
        assertEq(_hookBalance(poolKey.currency1), c1Before, "frozen: no currency1 surcharge");
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    /// @notice For any above-threshold external dislocation, a single-swap close is
    ///         surcharged and the whole capture belongs to LPs.
    function testFuzz_ExogenousAlwaysCapturedAndAllToLps(int24 refTick) public {
        refTick = int24(bound(int256(refTick),
            int256(uint256(gapThresholdTicks)) + 10, int256(1500)));

        oracle.setRef(poolId, refTick);

        uint256 c0Before = _hookBalance(poolKey.currency0);
        uint256 c1Before = _hookBalance(poolKey.currency1);

        uint256 idx = hook.gaps(poolId).length;   // the gap beforeSwap will push
        _swap(VIK, false, -300_000e18);

        uint256 captured = (_hookBalance(poolKey.currency0) - c0Before)
                         + (_hookBalance(poolKey.currency1) - c1Before);
        assertGt(captured, 0, "exogenous dislocation went uncaptured");

        assertEq(hook.gapAt(poolId, idx).totalContribution, 0,
            "no swap in this pool widened the gap, so the ledger must be empty");
        assertEq(_contrib(idx, VIK), 0, "corrector must hold no credit at any gap size");

        // If VIK overshot past the reference by more than the threshold, the far-side
        // dislocation is a NEW gap VIK created and is credited to VIK (R3). That is not
        // credit on the gap VIK closed.
        uint256 open = hook.openGapIdx(poolId);
        if (open != 0 && open != idx) {     // idx itself may still be open on a partial close
            assertGt(open, idx, "any other open gap is a later, far-side one");
            BackdraftHook.Gap memory far = hook.gapAt(poolId, open);
            assertEq(far.totalContribution, far.maxAbsGap, "overshooter owns the far-side gap");
        }
    }
}
