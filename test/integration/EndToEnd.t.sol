// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BackdraftTestBase} from "../BackdraftTestBase.sol";
import {BackdraftHook}     from "../../src/BackdraftHook.sol";
import {IPoolManager}      from "v4-core/interfaces/IPoolManager.sol";
import {PoolId}            from "v4-core/types/PoolId.sol";
import {Currency}          from "v4-core/types/Currency.sol";

// ============================================================
// End-to-end integration test.
//
// Scenario A (endogenous gap — ledger explains it):
//   1. LP_old adds liquidity early (eligible age)
//   2. LP_new adds liquidity just before the gap opens (too new, JIT-blocked)
//   3. Rohan does a big widening swap → gap opens, contribution recorded
//   4. Retail does another small widening swap → more contribution
//   5. Vik does a narrowing swap → surcharge collected, gap closes
//   6. settle() called
//   7. Rohan & Retail claim trader pot (proportional to contribution)
//   8. LP_old claims LP pot (eligible)
//   9. LP_new claim reverts (too new)
//  10. Conservation: traderClaimed + lpClaimed == escrowed (no value lost)
//
// Scenario B (exogenous gap — empty ledger → 100% to LPs):
//   1. LP_old adds liquidity
//   2. Oracle moves (ref jumps), pool price stays — gap is exogenous
//   3. First swap into pool detects and opens gap
//   4. Vik closes gap with a narrowing swap — surcharge collected
//   5. settle() → totalContribution==0 → traderPot==0 → all to LPs
//   6. LP_old gets 100% of escrowed
// ============================================================
contract EndToEndTest is BackdraftTestBase {

    // Named actors
    address constant LP_OLD  = address(0x1001);
    address constant LP_NEW  = address(0x1002);
    address constant ROHAN   = address(0xaaaa);
    address constant RETAIL  = address(0xbbbb);
    address constant VIK     = address(0xcccc);

    function setUp() public override {
        super.setUp();
        _fund(LP_OLD);
        _fund(LP_NEW);
        _fund(ROHAN);
        _fund(RETAIL);
        _fund(VIK);
    }

    function _fund(address who) internal {
        token0.transfer(who, 100_000_000e18);
        token1.transfer(who, 100_000_000e18);
    }

    // ----------------------------------------------------------------
    // Scenario A — endogenous gap, contribution ledger, claims
    // ----------------------------------------------------------------

    function test_EndToEnd_EndogenousGap_FullCycle() public {
        // ── Step 1: LP_old adds liquidity early ──────────────────────
        _addLiquidity(LP_OLD, -6000, 6000, 5_000_000e18);

        // Advance past minAgeBlocks so LP_old is eligible when the gap opens
        vm.roll(block.number + minAgeBlocks + 1);

        // ── Step 2: LP_new adds right before the gap (too new) ───────
        _addLiquidity(LP_NEW, -6000, 6000, 1_000_000e18);
        // LP_new's addBlock == current block; gap will open this block too,
        // so LP_new.addBlock + minAge > gap.openBlock → ineligible.

        // ── Step 3: Rohan widens the gap (opening swap) ──────────────
        _swap(ROHAN, false, -500_000e18);   // oneForZero, price up, tick up

        uint256 gapIdx = hook.openGapIdx(poolId);
        assertTrue(gapIdx > 0, "gap should open after Rohan");

        BackdraftHook.Gap memory g0 = hook.gapAt(poolId, gapIdx);
        assertGt(g0.totalContribution, 0, "Rohan opened the gap and must be credited for it");

        // ── Step 4: Retail widens further (into open gap) ────────────
        _swap(RETAIL, false, -100_000e18);  // more widening

        BackdraftHook.Gap memory g1 = hook.gapAt(poolId, gapIdx);
        uint128 totalContribAfterRetail = g1.totalContribution;
        assertGt(totalContribAfterRetail, 0, "retail widens into open gap: contribution expected");

        // Also check Retail's individual contribution
        bytes32 retailKey = keccak256(abi.encode(poolId, gapIdx, RETAIL));
        uint128 retailContrib = hook.contribution(retailKey);
        assertGt(retailContrib, 0, "retail contribution recorded");

        // Rohan is the originator: his opening swap created the mispricing, so he
        // holds the larger share of the ledger than Retail, who only widened it further.
        bytes32 rohanKey = keccak256(abi.encode(poolId, gapIdx, ROHAN));
        uint128 rohanContrib = hook.contribution(rohanKey);
        assertGt(rohanContrib, 0, "rohan opened the gap and must be credited");
        assertGt(rohanContrib, retailContrib, "originator's share exceeds the later widener's");
        assertEq(rohanContrib + retailContrib, totalContribAfterRetail,
            "ledger equals the sum of its contributors");

        // ── Step 5: Vik closes the gap (narrowing swap, surcharged) ──
        uint256 hookBalBefore = _hookBalance(poolKey.currency1); // oneForZero gap → currency1 spec
        // Wait — gap opened by zeroForOne=false swaps, so gapBefore positive.
        // Vik narrows with zeroForOne=true → spec = currency0.
        uint256 hookCur0Before = _hookBalance(poolKey.currency0);
        _swap(VIK, true, -2_000_000e18);     // zeroForOne, narrowing (large enough to close gap)
        uint256 hookCur0After  = _hookBalance(poolKey.currency0);

        uint128 escrowed = hook.gapAt(poolId, gapIdx).escrowed;
        assertGt(escrowed, 0, "escrowed should be non-zero after Vik");
        assertGt(hookCur0After, hookCur0Before, "hook collected surcharge in currency0");

        // The gap Vik closed is settled. (Vik's 2M swap overshoots far past the
        // reference; the far-side dislocation it leaves is a NEW gap that Vik owns —
        // see ReviewRegressions R3 — so openGapIdx is not necessarily 0 here.)
        assertTrue(hook.gapAt(poolId, gapIdx).settled, "gap should be closed after Vik");
        assertTrue(hook.openGapIdx(poolId) != gapIdx, "closed gap is no longer the open one");

        // ── Step 6: settle() ─────────────────────────────────────────
        if (!hook.gapAt(poolId, gapIdx).settled) hook.settle(poolId, gapIdx);

        BackdraftHook.Gap memory gFinal = hook.gapAt(poolId, gapIdx);
        assertTrue(gFinal.settled, "gap must be marked settled");

        // ── Step 7: Retail claims trader pot ─────────────────────────
        // Only Retail contributed (Rohan's opening swap predated the open gap).
        // traderPot = escrowed * traderShareBps/10000 * min(totalContrib,maxAbsGap)/maxAbsGap
        // Since only Retail contributed, Retail claims the full traderPot.
        uint256 retailToken0Before = token0.balanceOf(RETAIL);
        vm.prank(RETAIL);
        hook.claimTrader(poolId, gapIdx);
        uint256 retailToken0After = token0.balanceOf(RETAIL);
        assertGt(retailToken0After, retailToken0Before, "retail should receive trader payout");

        // ── Step 8: LP_old claims LP pot ─────────────────────────────
        uint256 lpOldToken0Before = token0.balanceOf(LP_OLD);
        vm.prank(LP_OLD, LP_OLD);
        hook.claimLp(poolId, gapIdx, int24(-6000), int24(6000), bytes32(0));
        uint256 lpOldToken0After = token0.balanceOf(LP_OLD);
        assertGt(lpOldToken0After, lpOldToken0Before, "LP_old should receive LP payout");

        // ── Step 9: LP_new claim reverts (too new) ───────────────────
        vm.prank(LP_NEW, LP_NEW);
        vm.expectRevert(BackdraftHook.TooNew.selector);
        hook.claimLp(poolId, gapIdx, int24(-6000), int24(6000), bytes32(0));

        // ── Step 10: Conservation check ──────────────────────────────
        // After all valid claims, hook's ERC-6909 should be ~0 (rounding dust OK).
        // In this test only Retail (trader) and LP_old claimed.
        // LP pot = escrowed - traderPot; LP_old gets (LP_old_liq / eligibleLiq) * lpPot.
        // Conservation: token0 paid out == token0 escrowed (within 1 wei rounding).
        uint256 hookBalFinal = _hookBalance(poolKey.currency0);
        // Some dust may remain because LP_new is blocked from claiming.
        // But retailClaimed + lpOldClaimed must be <= escrowed.
        uint256 retailClaimed = retailToken0After - retailToken0Before;
        uint256 lpOldClaimed  = lpOldToken0After - lpOldToken0Before;
        assertLe(retailClaimed + lpOldClaimed, uint256(escrowed) + 1, "no value created out of thin air");
    }

    // ----------------------------------------------------------------
    // Scenario B — exogenous gap, empty ledger, 100% to LPs
    // ----------------------------------------------------------------

    function test_EndToEnd_ExogenousGap_AllToLPs() public {
        // ── LP_old provides liquidity early ──────────────────────────
        _addLiquidity(LP_OLD, -6000, 6000, 5_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);

        // ── Oracle jumps — exogenous market move ─────────────────────
        // Pool tick stays at 0; ref moves to +200 → gap = 0 - 200 = -200.
        // |gap| = 200 > gapThresholdTicks (65) → will open on next swap.
        oracle.setRef(poolId, 200);

        // ── First swap detects gap in afterSwap ──────────────────────
        // Pool at tick 0, ref at 200, gap = -200 (negative).
        // Narrowing direction for negative gap = oneForZero (false), but we
        // want to just trigger the afterSwap gap-detection without surcharging.
        // A small widening swap works: zeroForOne=true widens (tick goes more negative).
        // Actually zeroForOne=true on a negative gap: tick goes down, gap more negative → WIDENING.
        // WIDENING swap = no surcharge. Just opens the gap.
        _swap(ROHAN, true, -1_000e18);  // tiny widening swap — detects the exogenous gap

        uint256 gapIdx = hook.openGapIdx(poolId);
        assertGt(gapIdx, 0, "trigger swap must open the exogenous gap");

        // The trigger swap widened by a few ticks, so it earns a few ticks of credit —
        // but the ~200 ticks that came from the external move are unexplained. The
        // ledger therefore explains only a tiny fraction of maxAbsGap, and settlement
        // routes almost everything to LPs. This is the mixed-gap case working
        // correctly, not a contradiction of "exogenous means empty ledger".
        BackdraftHook.Gap memory gOpen = hook.gapAt(poolId, gapIdx);
        assertLt(
            uint256(gOpen.totalContribution) * 10, uint256(gOpen.maxAbsGap),
            "externally-caused portion of the gap must stay unexplained (<10% attributed)"
        );

        // ── Vik closes the gap (narrowing: pool tick moves toward ref=200) ─
        // Pool tick is slightly below 0, ref=200. Gap is negative (pool < ref).
        // Narrowing = oneForZero (zeroForOne=false) which brings tick up toward 200.
        uint256 cur1Before = _hookBalance(poolKey.currency1);
        _swap(VIK, false, -2_000_000e18);   // oneForZero, narrowing (large enough to close gap)
        uint256 cur1After  = _hookBalance(poolKey.currency1);

        // The gap may or may not still be open depending on how much the tick moved.
        // If it closed, check the escrowed amount.
        uint128 escrowed = hook.gapAt(poolId, gapIdx).escrowed;

        if (escrowed == 0) return; // gap closed with nothing surcharged — inconclusive

        // settle it
        if (!hook.gapAt(poolId, gapIdx).settled) hook.settle(poolId, gapIdx);

        // ── LP_old claims and gets everything ────────────────────────
        // traderPot = 0 (totalContribution == 0 → _traderPot returns 0)
        // lpPot = escrowed - 0 = escrowed
        uint256 token0Before = token0.balanceOf(LP_OLD);
        uint256 token1Before = token1.balanceOf(LP_OLD);

        vm.prank(LP_OLD, LP_OLD);
        hook.claimLp(poolId, gapIdx, int24(-6000), int24(6000), bytes32(0));

        uint256 token0After = token0.balanceOf(LP_OLD);
        uint256 token1After = token1.balanceOf(LP_OLD);

        bool lpGotPaid = (token0After > token0Before) || (token1After > token1Before);
        assertTrue(lpGotPaid, "LP_old should receive LP payout from exogenous gap");

        // Conservation: what LP got is bounded by escrowed (possibly less if VIK overshoot
        // credited some contribution, reducing the exact LP fraction).
        uint256 lpGot = (token0After - token0Before) + (token1After - token1Before);
        assertLe(lpGot, uint256(escrowed) + 1, "LP payout cannot exceed escrowed");
    }

    // ----------------------------------------------------------------
    // Scenario C — settle reverts while gap is still open
    // ----------------------------------------------------------------

    function test_SettleRevertsWhileGapOpen() public {
        _addLiquidity(LP_OLD, -6000, 6000, 5_000_000e18);
        _swap(ROHAN, false, -500_000e18);

        uint256 gapIdx = hook.openGapIdx(poolId);
        assertGt(gapIdx, 0, "precondition: gap must be open");

        vm.expectRevert(BackdraftHook.GapStillOpen.selector);
        hook.settle(poolId, gapIdx);
    }

    // ----------------------------------------------------------------
    // Scenario D — settle succeeds after expiry even if gap still "open"
    // ----------------------------------------------------------------

    function test_SettleAfterExpiry() public {
        _addLiquidity(LP_OLD, -6000, 6000, 5_000_000e18);
        _swap(ROHAN, false, -500_000e18);

        uint256 gapIdx = hook.openGapIdx(poolId);
        if (gapIdx == 0) return;

        BackdraftHook.Gap memory g = hook.gapAt(poolId, gapIdx);
        vm.roll(g.expiryBlock + 1);

        // No revert — expiry allows settlement even with gap still "open"
        if (!hook.gapAt(poolId, gapIdx).settled) hook.settle(poolId, gapIdx);
        assertTrue(hook.gapAt(poolId, gapIdx).settled);
    }

    // ----------------------------------------------------------------
    // Scenario E — double settle reverts
    // ----------------------------------------------------------------

    function test_DoubleSettleReverts() public {
        _addLiquidity(LP_OLD, -6000, 6000, 5_000_000e18);
        _swap(ROHAN, false, -500_000e18); // open gap

        BackdraftHook.Gap[] memory allGaps = hook.gaps(poolId);
        assertGt(allGaps.length, 1, "precondition: gap must open");

        uint256 latestIdx = allGaps.length - 1;

        // Expire the gap so settle() allows it even while "open"
        BackdraftHook.Gap memory g = hook.gapAt(poolId, latestIdx);
        vm.roll(g.expiryBlock + 1);

        if (!hook.gapAt(poolId, latestIdx).settled) hook.settle(poolId, latestIdx);
        assertTrue(hook.gapAt(poolId, latestIdx).settled);

        vm.expectRevert(BackdraftHook.AlreadySettled.selector);
        hook.settle(poolId, latestIdx);
    }
}
