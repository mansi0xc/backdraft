// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BackdraftTestBase} from "../BackdraftTestBase.sol";
import {BackdraftHook}     from "../../src/BackdraftHook.sol";
import {StateLibrary}      from "v4-core/libraries/StateLibrary.sol";
import {LPFeeLibrary}      from "v4-core/libraries/LPFeeLibrary.sol";
import {IPoolManager}      from "v4-core/interfaces/IPoolManager.sol";
import {Currency}          from "v4-core/types/Currency.sol";

// ============================================================
// Regressions from the external review of 2026-09-03. Each test failed on the
// pre-review code and pins the fix.
//
//   R1  claim after sweep was paid out of OTHER gaps' escrow (solvency)
//   R2  sweep donates to whoever is in range at sweep time (JIT) — DOCUMENTED, not fixed
//   R3  a swap crossing the reference opened an endogenous gap with an empty ledger
//   R4  fee flip inverts "closing costs more than widening" at realistic gap sizes
//       — DOCUMENTED, asserted here so the config surface says so
//   R5  an old LP withdrawing inside the lookback masked a JIT add in the denominator
//   R6  setPoolCfg accepted traderShareBps > 100%, which reverted every closing swap
//   R7  reference crossing the pool with no swap made the next narrowing swap revert
//       with EscrowCurrencyMismatch until expiry (found by the rewired invariant)
// ============================================================
contract ReviewRegressionsTest is BackdraftTestBase {
    address constant LP_A  = address(0x1001);
    address constant LP_B  = address(0x1002);
    address constant ROHAN = address(0xaaaa);
    address constant VIK   = address(0xbbbb);
    address constant JIT   = address(0xcccc);

    function setUp() public override {
        super.setUp();
        address[5] memory who = [LP_A, LP_B, ROHAN, VIK, JIT];
        for (uint256 i; i < 5; i++) {
            token0.transfer(who[i], 100_000_000e18);
            token1.transfer(who[i], 100_000_000e18);
        }
    }

    function _cycle(address widener, address closer) internal returns (uint256 idx) {
        _swap(widener, false, -500_000e18);
        idx = hook.openGapIdx(poolId);
        require(idx != 0, "precondition: gap must open");
        _swap(closer, true, -2_000_000e18);
        if (hook.openGapIdx(poolId) == idx) vm.roll(block.number + expiryBlocks + 1);
        if (!hook.gapAt(poolId, idx).settled) hook.settle(poolId, idx);
    }

    function _modify(address who, int24 lo, int24 hi, int256 delta, bytes32 salt) internal {
        vm.startPrank(who, who);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            poolKey, IPoolManager.ModifyLiquidityParams(lo, hi, delta, salt), abi.encode(who)
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ R1

    /// @notice After a sweep the gap owes nothing. A late claim must revert, and the
    ///         hook must still hold every other gap's outstanding escrow.
    function test_R1_ClaimAfterSweepRevertsAndKeepsOtherGapsSolvent() public {
        _addLiquidity(LP_A, -6000, 6000, 10_000_000e18);
        _addLiquidity(LP_B, -6000, 6000, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);

        uint256 idx1 = _cycle(ROHAN, VIK);
        BackdraftHook.Gap memory g1 = hook.gapAt(poolId, idx1);
        Currency cur = g1.isCurrency0 ? poolKey.currency0 : poolKey.currency1;

        // Let anything the overshoot opened on the far side expire, then reset the
        // reference to the pool so the second cycle starts from a clean state.
        vm.roll(block.number + expiryBlocks + 1);
        oracle.setRef(poolId, _poolTick());
        uint256 idx2 = _cycle(ROHAN, VIK);
        BackdraftHook.Gap memory g2 = hook.gapAt(poolId, idx2);
        require(g2.isCurrency0 == g1.isCurrency0, "precondition: same currency");

        vm.roll(uint256(g1.expiryBlock) + sweepGraceBlocks + 1);
        hook.sweepUnclaimed(poolId, idx1);

        g1 = hook.gapAt(poolId, idx1);
        assertEq(uint256(g1.lpPaid) + uint256(g1.traderPaid), uint256(g1.escrowed),
            "a swept gap must record its pots as fully paid");

        vm.prank(LP_A, LP_A);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "swept"));
        hook.claimLp(poolId, idx1, -6000, 6000, bytes32(0));

        uint256 g2Obligation = uint256(g2.escrowed) - g2.lpPaid - g2.traderPaid;
        assertGe(_hookBalance(cur), g2Obligation, "gap 2's escrow must be intact");
    }

    function test_R1_ClaimTraderAfterSweepReverts() public {
        _addLiquidity(LP_A, -6000, 6000, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        _swap(ROHAN, false, -200_000e18);           // credited widener
        _swap(VIK, true, -2_000_000e18);
        if (hook.openGapIdx(poolId) == idx) vm.roll(block.number + expiryBlocks + 1);
        if (!hook.gapAt(poolId, idx).settled) hook.settle(poolId, idx);
        require(hook.gapAt(poolId, idx).totalContribution > 0, "precondition: ledger");

        vm.roll(uint256(hook.gapAt(poolId, idx).expiryBlock) + sweepGraceBlocks + 1);
        hook.sweepUnclaimed(poolId, idx);

        vm.prank(ROHAN, ROHAN);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "swept"));
        hook.claimTrader(poolId, idx);
    }

    // ------------------------------------------------------------------ R2

    /// @notice The swept remainder no longer touches the pool. It is carried, in the
    ///         hook's own balance, to the next gap that escrows in the same currency.
    function test_R2_SweepCarriesRemainderInsteadOfDonating() public {
        _addLiquidity(LP_A, -6000, 6000, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
        uint256 idx = _cycle(ROHAN, VIK);
        BackdraftHook.Gap memory g = hook.gapAt(poolId, idx);
        vm.roll(uint256(g.expiryBlock) + sweepGraceBlocks + 1);

        // JIT adds 90x the honest liquidity right before the sweep, as before.
        _modify(JIT, -6000, 6000, int256(90_000_000e18), bytes32(uint256(1)));
        (uint256 f0, uint256 f1) = StateLibrary.getFeeGrowthGlobals(manager, poolId);
        uint256 remainder = uint256(g.escrowed) - g.lpPaid - g.traderPaid;
        hook.sweepUnclaimed(poolId, idx);
        (uint256 a0, uint256 a1) = StateLibrary.getFeeGrowthGlobals(manager, poolId);

        assertEq(a0, f0, "no fee growth: nothing was donated");
        assertEq(a1, f1, "no fee growth: nothing was donated");
        assertEq(hook.pendingCarry(poolId, g.isCurrency0 ? 1 : 0), remainder, "carried in full");
    }

    /// @notice The carry lands in the NEXT gap's LP pot, is claimable only by LPs that
    ///         were old enough at that gap's open, and never enters the trader pot.
    function test_R2_CarryIsClaimedByAgeFilteredLpsOfTheNextGap() public {
        _addLiquidity(LP_A, -6000, 6000, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);

        uint256 idx1 = _cycle(ROHAN, VIK);
        BackdraftHook.Gap memory g1 = hook.gapAt(poolId, idx1);
        Currency cur = g1.isCurrency0 ? poolKey.currency0 : poolKey.currency1;
        vm.roll(uint256(g1.expiryBlock) + sweepGraceBlocks + 1);
        hook.sweepUnclaimed(poolId, idx1);
        uint256 carried = hook.pendingCarry(poolId, g1.isCurrency0 ? 1 : 0);
        assertGt(carried, 0, "precondition: something carried");

        // JIT shows up now, one block before the next gap. It is NOT eligible.
        _modify(JIT, -6000, 6000, int256(90_000_000e18), bytes32(uint256(1)));

        oracle.setRef(poolId, _poolTick());
        uint256 idx2 = _cycle(ROHAN, VIK);
        BackdraftHook.Gap memory g2 = hook.gapAt(poolId, idx2);
        require(g2.isCurrency0 == g1.isCurrency0, "precondition: same currency");
        assertEq(g2.lpCarry, carried, "carry attached to the next gap");
        assertEq(hook.pendingCarry(poolId, g1.isCurrency0 ? 1 : 0), 0, "and cleared");

        // Trader pot ignores the carry.
        uint256 tp = uint256(g2.escrowed) * traderShareBps / 10_000;   // ledger explains fully
        // JIT cannot claim.
        vm.prank(JIT, JIT);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "too new"));
        hook.claimLp(poolId, idx2, -6000, 6000, bytes32(uint256(1)));

        // LP_A's pot is escrow − traderPot + carry.
        uint256 before = _hookBalance(cur);
        vm.prank(LP_A, LP_A);
        hook.claimLp(poolId, idx2, -6000, 6000, bytes32(0));
        uint256 paid = before - _hookBalance(cur);
        assertGt(paid, uint256(g2.escrowed) - tp, "LP_A received more than gap 2's own LP pot");
        assertLe(paid, uint256(g2.escrowed) - tp + carried, "and no more than pot + carry");
    }

    /// @notice A gap that escrows in the OTHER currency leaves the carry untouched.
    function test_R2_CarryWaitsForAGapInItsOwnCurrency() public {
        _addLiquidity(LP_A, -6000, 6000, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
        uint256 idx1 = _cycle(ROHAN, VIK);
        BackdraftHook.Gap memory g1 = hook.gapAt(poolId, idx1);
        vm.roll(uint256(g1.expiryBlock) + sweepGraceBlocks + 1);
        hook.sweepUnclaimed(poolId, idx1);
        uint256 carried = hook.pendingCarry(poolId, g1.isCurrency0 ? 1 : 0);

        // Open a gap on the other side so the closer pays in the other currency.
        oracle.setRef(poolId, _poolTick());
        _swap(ROHAN, true, -500_000e18);
        uint256 idx2 = hook.openGapIdx(poolId);
        _swap(VIK, false, -100_000e18);          // partial close, other currency
        BackdraftHook.Gap memory g2 = hook.gapAt(poolId, idx2);
        assertTrue(g2.isCurrency0 != g1.isCurrency0, "precondition: other currency");
        assertEq(g2.lpCarry, 0, "carry not attached across currencies");
        assertEq(hook.pendingCarry(poolId, g1.isCurrency0 ? 1 : 0), carried, "still pending");
    }

    // ------------------------------------------------------------------ R3

    /// @notice A swap that enters narrowing, crosses the reference, and leaves an
    ///         above-threshold gap on the far side CREATED that gap and is its sole
    ///         contributor. It must not settle as exogenous.
    function test_R3_CrossingSwapIsCreditedForTheWholeExitGap() public {
        _addLiquidity(LP_A, -6000, 6000, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
        oracle.setRef(poolId, -40);                  // sub-threshold, pool at 0
        _swap(ROHAN, true, -500_000e18);             // drives tick well below -40

        uint256 idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "gap opened");
        BackdraftHook.Gap memory g = hook.gapAt(poolId, idx);
        assertEq(g.totalContribution, g.maxAbsGap, "the crossing swap explains the whole gap");
        assertEq(hook.contribution(keccak256(abi.encode(poolId, idx, ROHAN))), g.maxAbsGap);
    }

    /// @notice And when a gap is already open on the near side: the crossing swap closes
    ///         it, does not inflate its maxAbsGap, and opens a fresh far-side gap it owns.
    function test_R3_CrossingSwapClosesOldGapAndOpensCreditedNewOne() public {
        _addLiquidity(LP_A, -6000, 6000, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
        _swap(ROHAN, false, -500_000e18);            // endogenous gap, tick > 0
        uint256 idx1 = hook.openGapIdx(poolId);
        uint24 max1 = hook.gapAt(poolId, idx1).maxAbsGap;

        _swap(VIK, true, -3_000_000e18);             // overshoots far past the reference
        uint256 idx2 = hook.openGapIdx(poolId);
        assertTrue(hook.gapAt(poolId, idx1).settled, "old gap closed");
        assertEq(hook.gapAt(poolId, idx1).maxAbsGap, max1, "old maxAbsGap not inflated");
        assertGt(idx2, idx1, "new far-side gap opened");
        BackdraftHook.Gap memory g2 = hook.gapAt(poolId, idx2);
        assertEq(g2.totalContribution, g2.maxAbsGap, "overshooter owns the new gap");
        assertEq(hook.contribution(keccak256(abi.encode(poolId, idx1, VIK))), 0,
            "overshooter still earns nothing on the gap it closed");
    }

    // ------------------------------------------------------------------ R5

    /// @notice An old LP withdrawing inside the lookback must not cancel a JIT add out
    ///         of the recent-adds total.
    function test_R5_OldLpRemovalDoesNotMaskJitInDenominator() public {
        _addLiquidity(LP_A, -6000, 6000, 10_000_000e18);
        _addLiquidity(LP_B, -6000, 6000, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
        _modify(LP_B, -6000, 6000, -int256(10_000_000e18), bytes32(0));
        _modify(JIT, -6000, 6000, int256(10_000_000e18), bytes32(uint256(1)));
        _swap(ROHAN, false, -500_000e18);
        BackdraftHook.Gap memory g = hook.gapAt(poolId, hook.openGapIdx(poolId));
        assertEq(uint256(g.eligibleLiqAtOpen), 10_000_000e18, "only LP_A is eligible");
    }

    /// @notice The original griefing fix must still hold: a recent add-then-remove does
    ///         not zero the denominator.
    function test_R5_RecentAddThenRemoveStillNetsOut() public {
        _addLiquidity(LP_A, -6000, 6000, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
        _modify(JIT, -6000, 6000, int256(50_000_000e18), bytes32(uint256(1)));
        _modify(JIT, -6000, 6000, -int256(50_000_000e18), bytes32(uint256(1)));
        _swap(ROHAN, false, -500_000e18);
        BackdraftHook.Gap memory g = hook.gapAt(poolId, hook.openGapIdx(poolId));
        assertEq(uint256(g.eligibleLiqAtOpen), 10_000_000e18, "grief nets to zero");
    }

    // ------------------------------------------------------------------ R7

    /// @notice The reference crosses the pool while a gap is open, with no swap. The
    ///         next swap toward the new reference must NOT revert; the stale gap closes
    ///         and, if the new dislocation clears the threshold, a fresh gap opens.
    function test_R7_ReferenceCrossingPoolDoesNotBrickSwaps() public {
        _addLiquidity(LP_A, -6000, 6000, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);

        _swap(ROHAN, false, -500_000e18);            // pool above reference (0)
        uint256 idx = hook.openGapIdx(poolId);
        assertGt(idx, 0);
        int24 tickNow = _poolTick();
        assertTrue(hook.gapAt(poolId, idx).gapPositive);

        oracle.setRef(poolId, tickNow + 300);        // market leaps PAST the pool

        // Toward the new reference = oneForZero, the direction the old gap called widening.
        // Pre-fix: EscrowCurrencyMismatch revert.
        _swap(VIK, false, -100_000e18);

        assertTrue(hook.gapAt(poolId, idx).settled, "stale gap closed");
        uint256 idx2 = hook.openGapIdx(poolId);
        assertGt(idx2, idx, "fresh gap opened on the new dislocation");
        assertFalse(hook.gapAt(poolId, idx2).gapPositive, "with the new sign");
        assertGt(hook.gapAt(poolId, idx2).escrowed, 0, "and the corrector was surcharged");
    }

    // ------------------------------------------------------------------ R6

    function test_R6_SetPoolCfgRejectsTraderShareAbove100Pct() public {
        traderShareBps = 10_001;
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "traderShare > 100%"));
        _setPoolCfg();
    }

    function test_R6_SetPoolCfgRejectsSurchargeCapAbove100Pct() public {
        surchargeCapBps = 10_001;
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "surchargeCap > 100%"));
        _setPoolCfg();
    }
}

/// @notice R4. The FeeFlip suite only exercised the cap-bound regime, where the
///         surcharge (200 bps) dwarfs the discount (25 bps). At a 100-tick gap the
///         surcharge is 5 bps, and the unbounded discount made closing CHEAPER than
///         widening. The discount is now bounded by the surcharge on the same swap.
contract ReviewFeeFlipRegimeTest is BackdraftTestBase {
    address constant LP  = address(0x1001);
    address constant VIK = address(0xbbbb);

    function setUp() public override {
        poolFee = LPFeeLibrary.DYNAMIC_FEE_FLAG; baseFee = 3000; narrowingFee = 500;
        super.setUp();
        token0.transfer(LP, 100_000_000e18); token1.transfer(LP, 100_000_000e18);
        token0.transfer(VIK, 100_000_000e18); token1.transfer(VIK, 100_000_000e18);
        _addLiquidity(LP, -6000, 6000, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
    }

    /// @dev (fee paid, surcharge paid) by a closing swap of `notional` against `refTick`.
    function _closerCosts(int24 refTick, uint256 notional) internal returns (uint256 fee, uint256 surcharge) {
        oracle.setRef(poolId, refTick);
        uint128 liq = StateLibrary.getLiquidity(manager, poolId);
        (, uint256 gBefore) = StateLibrary.getFeeGrowthGlobals(manager, poolId);
        uint256 idx = hook.gaps(poolId).length;
        _swap(VIK, false, -int256(notional));
        (, uint256 gAfter) = StateLibrary.getFeeGrowthGlobals(manager, poolId);
        fee = ((gAfter - gBefore) * liq) >> 128;
        surcharge = hook.gapAt(poolId, idx).escrowed;
    }

    function test_R4_SmallGapDiscountIsBoundedBySurcharge() public {
        uint256 notional = 100_000e18;
        (uint256 fee, uint256 surcharge) = _closerCosts(100, notional);
        assertGt(surcharge, 0, "precondition: surcharged");
        assertLt(surcharge, notional * 25 / 1e4, "precondition: surcharge < full discount");
        // The discount rebates the surcharge exactly: closer pays baseFee on the full
        // notional, to rounding.
        assertApproxEqRel(fee + surcharge, notional * 3000 / 1e6, 1e15,
            "closer pays exactly the base fee when the surcharge is smaller than the discount");
        assertGe(fee + surcharge + 1e6, notional * 3000 / 1e6, "never cheaper than a widener");
    }

    function test_R4_LargeGapStillGetsTheFullDiscount() public {
        uint256 notional = 100_000e18;
        (uint256 fee, uint256 surcharge) = _closerCosts(3000, notional);   // cap binds
        // The pool fees what reaches it: notional minus the surcharge.
        assertApproxEqRel(fee, (notional - surcharge) * 500 / 1e6, 1e12, "full narrowingFee applies");
        assertGt(fee + surcharge, notional * 3000 / 1e6, "and the surcharge still dominates");
    }

    /// @notice Across gap sizes and notionals, a closer never pays less than a widener.
    function testFuzz_R4_ClosingNeverCheaperThanWidening(int24 refTick, uint96 raw) public {
        refTick = int24(bound(int256(refTick), 70, 4000));
        uint256 notional = uint256(bound(raw, 1_000e18, 300_000e18));
        (uint256 fee, uint256 surcharge) = _closerCosts(refTick, notional);
        assertGe(fee + surcharge + 1e6, notional * 3000 / 1e6, "closing costs at least baseFee");
    }
}
