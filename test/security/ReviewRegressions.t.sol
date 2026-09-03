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

    /// @notice DOCUMENTED LIMITATION, asserted so it cannot be forgotten: donate() pays
    ///         whatever liquidity is in range at sweep time, with no age filter. A
    ///         position one block old receives its pro-rata share of the remainder.
    function test_R2_SweepPaysJitLiquidity_KnownLimitation() public {
        _addLiquidity(LP_A, -6000, 6000, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
        uint256 idx = _cycle(ROHAN, VIK);
        BackdraftHook.Gap memory g = hook.gapAt(poolId, idx);
        vm.roll(uint256(g.expiryBlock) + sweepGraceBlocks + 1);

        _modify(JIT, -6000, 6000, int256(90_000_000e18), bytes32(uint256(1)));
        uint128 inRange = StateLibrary.getLiquidity(manager, poolId);
        assertEq(inRange, 100_000_000e18, "10M honest + 90M one-block-old");

        (uint256 f0, uint256 f1) = StateLibrary.getFeeGrowthGlobals(manager, poolId);
        hook.sweepUnclaimed(poolId, idx);
        (uint256 a0, uint256 a1) = StateLibrary.getFeeGrowthGlobals(manager, poolId);
        uint256 donated = (((a0 - f0) + (a1 - f1)) * inRange) >> 128;
        assertGt(donated, 0, "sweep donated");
        // 90% of the remainder is now claimable by the JIT position.
        // This is the sweep-side JIT vector. See README Limitations.
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

/// @notice R4. The FeeFlip suite only exercises the cap-bound regime. At a 100-tick gap
///         the fee discount (25 bps) is 5x the surcharge (5 bps) and closing is CHEAPER
///         than widening. This is the mechanism as shipped; the test states it rather
///         than hides it. If the flip is bounded by the surcharge, invert the assertion.
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

    function test_R4_AtRealisticGapClosingIsCheaperThanWidening_KnownInversion() public {
        oracle.setRef(poolId, 100);
        uint256 notional = 100_000e18;
        uint128 liq = StateLibrary.getLiquidity(manager, poolId);
        (, uint256 gBefore) = StateLibrary.getFeeGrowthGlobals(manager, poolId);
        _swap(VIK, false, -int256(notional));
        (, uint256 gAfter) = StateLibrary.getFeeGrowthGlobals(manager, poolId);
        uint256 fee = ((gAfter - gBefore) * liq) >> 128;
        uint256 surcharge = hook.gapAt(poolId, hook.gaps(poolId).length - 1).escrowed;
        uint256 closerBps = (fee + surcharge) * 1e4 / notional;
        uint256 widenerBps = 30;
        assertLt(closerBps, widenerBps, "at a 100-tick gap the closer pays LESS than a widener");
        assertLt(surcharge, notional * 25 / 1e4, "surcharge (5 bps) < fee discount (25 bps)");
    }
}
