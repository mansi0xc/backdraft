// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test}              from "forge-std/Test.sol";
import {SplitV3Reference}  from "../../src/references/SplitV3Reference.sol";
import {MockV3Pool}        from "../mocks/MockV3Pool.sol";
import {PoolId}            from "v4-core/types/PoolId.sol";

// ============================================================
// Truncated reference (appendix §7).
//
// The reference the hook SEES may move at most B ticks per block from its last committed
// value. Guard and truncation are separate stages doing different jobs: the guard decides
// whether a read is trusted at all, truncation decides how far a trusted read is allowed
// to move the hook's view in one step.
//
// Why it exists. §10 measured two attacks the guard cannot close together — masking (push
// the reference until the gap hides) and freezing (push past the tolerance so the hook
// stops acting). Both are one-shot: the attacker pays once and moves the hook's view as
// far as their capital allows. Truncation makes the push RATE-LIMITED. Masking a 400-tick
// gap at B = 16 needs 25 consecutive blocks of sustained push instead of one, and a
// single-block glitch enters the hook's view as at most 16 ticks instead of 400.
//
// What it costs. A genuine move larger than B is seen with a lag of ceil(move / B)
// blocks, during which the pool leads the crawling reference. Measured phantom cost is
// regime-dependent and NOT monotone in B (§7), which is why B = 0 — raw, no truncation —
// is the default and this is shipped disabled.
// ============================================================
contract ReferenceTruncationTest is Test {

    SplitV3Reference ref;
    MockV3Pool fast;
    MockV3Pool deep;
    PoolId constant ID = PoolId.wrap(bytes32(uint256(1)));

    uint32 constant WINDOW     = 1800;
    uint24 constant MAX_DEV    = 50;
    uint24 constant FREEZE_DEV = 250;
    uint16 constant B          = 16;     // p99 of honest per-block movement, worst regime
    int24  constant START      = 1000;

    function setUp() public {
        ref  = new SplitV3Reference(address(this));
        fast = new MockV3Pool(START);
        deep = new MockV3Pool(START);
        _setDeepTwap(START);

        _configure(10_000, 20_000);      // guard wide open: isolate truncation
        ref.setMaxTicksPerBlock(ID, B);
        vm.roll(100);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _configure(uint24 guardDev, uint24 freezeDev) internal {
        ref.setConfig(ID, SplitV3Reference.Config({
            fastPool:          address(fast),
            deepPool:          address(deep),
            twapWindow:        WINDOW,
            guardMaxDevTicks:  guardDev,
            freezeMaxDevTicks: freezeDev,
            invertTicks:       false
        }));
    }

    function _setDeepTwap(int24 t) internal {
        deep.setCumulatives(0, int56(int256(t) * int256(uint256(WINDOW))));
    }

    /// Move both pools and the deep TWAP together — an honest market move that no guard
    /// condition should flag, so only truncation is exercised.
    function _honestMove(int24 t) internal {
        fast.setTick(t);
        deep.setTick(t);
        _setDeepTwap(t);
    }

    function _update() internal returns (int24 t) {
        bool ok;
        (t, ok, ) = ref.updateRefTick(ID);
        assertTrue(ok, "expected a trusted read");
    }

    function _absDiff(int24 a, int24 b) internal pure returns (uint256) {
        return a >= b ? uint256(uint24(a - b)) : uint256(uint24(b - a));
    }

    // ==================================================================
    // Compatibility — these protect the rest of the suite
    // ==================================================================

    /// @notice B = 0 is the default and must be byte-identical to the untruncated path.
    function test_BoundZeroIsRaw() public {
        ref.setMaxTicksPerBlock(ID, 0);
        _update();
        vm.roll(101);
        fast.setTick(START + 700);
        assertEq(_update(), START + 700, "B=0 must pass raw through unchanged");
    }

    function test_DefaultBoundIsZero() public {
        PoolId other = PoolId.wrap(bytes32(uint256(2)));
        assertEq(ref.maxTicksPerBlock(other), 0, "truncation must be opt-in");
    }

    /// @notice First read has no anchor to bound against, so it seeds at raw.
    function test_FirstReadSeedsAtRaw() public {
        fast.setTick(START + 700);
        assertEq(_update(), START + 700, "no anchor yet: first read is raw");
        (int24 t, uint48 blk, bool seeded) = ref.anchors(ID);
        assertEq(t, START + 700);
        assertEq(blk, 100);
        assertTrue(seeded);
    }

    /// @notice getRefTick must agree with updateRefTick and must not move the anchor.
    function test_ViewMatchesUpdateAndCommitsNothing() public {
        _update();
        vm.roll(101);
        fast.setTick(START + 400);

        (int24 viewed, bool ok, ) = ref.getRefTick(ID);
        assertTrue(ok);
        (int24 anchorTick,,) = ref.anchors(ID);
        assertEq(anchorTick, START, "view must not move the anchor");
        assertEq(viewed, _update(), "view and update must agree at the same block");
    }

    /// @notice THE test for the design decision in the header: divTicks is computed on the
    ///         RAW reads. If it were derived from the clamped value, a push would be
    ///         hidden from the signal that prices it, and truncation would silently
    ///         disable the graduated multiplier.
    function test_DivergenceIsMeasuredOnRawNotOnTheClampedValue() public {
        _configure(MAX_DEV, 0);       // backstop off so a large divergence still reads
        _update();

        vm.roll(101);
        fast.setTick(START + 400);    // fast diverges from deep by 400

        ( , , uint24 divTruncated) = ref.getRefTick(ID);

        // Same raw inputs, truncation disabled.
        ref.setMaxTicksPerBlock(ID, 0);
        (int24 rawTick, , uint24 divRaw) = ref.getRefTick(ID);

        assertEq(divTruncated, divRaw, "divTicks must not depend on the bound");
        assertEq(divRaw, 400, "divergence is the raw fast-deep distance");
        assertEq(rawTick, START + 400, "and the raw reference really did move 400");
    }

    // ==================================================================
    // The glitch case — what truncation is for
    // ==================================================================

    /// @notice A push-and-revert across two blocks. Raw sees the full 400-tick excursion;
    ///         truncation sees 16, below the 65-tick gap threshold, so no gap ever opens.
    function test_GlitchIsSeenAsAtMostB() public {
        _update();                                   // anchor = 1000 @ block 100

        vm.roll(101);
        fast.setTick(START + 400);                   // glitch
        int24 seen = _update();
        assertEq(seen, START + int24(uint24(B)), "one block: capped at B");
        assertLt(_absDiff(seen, START), 65, "must stay under the gap threshold");

        vm.roll(102);
        fast.setTick(START);                         // arbitrage reverts it
        assertEq(_update(), START, "reverted glitch: reference is back at raw");
    }

    /// @notice Same-block push has zero allowance. This is the in-block manipulation the
    ///         per-swap measurement in §7 was built to see.
    function test_SameBlockPushIsInvisible() public {
        _update();
        fast.setTick(START + 400);
        assertEq(_update(), START, "same block: the reference cannot move at all");
    }

    // ==================================================================
    // The cost — a real move is lagged, then caught, never overshot
    // ==================================================================

    function test_RealMoveIsLaggedThenCaught() public {
        _update();
        _honestMove(START + 400);

        int24 prev = START;
        for (uint256 i = 1; i <= 25; i++) {
            vm.roll(100 + i);
            int24 seen = _update();
            assertTrue(seen >= prev, "must be monotone toward raw");
            assertTrue(seen <= START + 400, "must never overshoot raw");
            assertLe(_absDiff(seen, prev), B, "per-block step bounded by B");
            prev = seen;
        }
        assertEq(prev, START + 400, "ceil(400/16) = 25 blocks to converge");
    }

    /// @notice Allowance accumulates across unread blocks, so a pool nobody swaps in for
    ///         an hour is not stuck behind the market. This is what makes the two-stage
    ///         read safe to add later: skipping the oracle on a cheap-path block costs
    ///         nothing, because the skipped blocks still count.
    function test_AllowanceAccumulatesOverIdleBlocks() public {
        _update();
        _honestMove(START - 400);
        vm.roll(100 + 25);
        assertEq(_update(), START - 400, "25 idle blocks x 16 = 400 of allowance");
    }

    function test_NegativeDirectionIsSymmetric() public {
        _update();
        vm.roll(101);
        fast.setTick(START - 400);
        assertEq(_update(), START - int24(uint24(B)));
    }

    // ==================================================================
    // Composition with the guard
    // ==================================================================

    /// @notice The guard runs first. A read it rejects moves nothing — and the blocks
    ///         spent frozen still count toward the allowance, so a freeze cannot
    ///         manufacture a lag that compounds with the bound.
    function test_FrozenReadCommitsNothingThenCatchesUp() public {
        _configure(MAX_DEV, FREEZE_DEV);
        _update();                                   // anchor 1000 @ 100

        vm.roll(101);
        fast.setTick(START + 400);                   // divergence 400 > backstop 250
        (int24 t, bool ok, uint24 div) = ref.updateRefTick(ID);
        assertFalse(ok, "backstop must freeze");
        assertEq(t, 0);
        assertEq(div, 400, "divergence still reported while frozen");

        (int24 anchorTick, uint48 anchorBlk,) = ref.anchors(ID);
        assertEq(anchorTick, START, "frozen read must not move the anchor");
        assertEq(anchorBlk, 100,   "nor its block");

        vm.roll(110);
        _honestMove(START + 144);                    // sources agree again
        assertEq(_update(), START + 144,
            "10 elapsed blocks x 16 = 160 of allowance: caught up in one read");
    }

    /// @notice The two stages catch different things. A 40-tick push is inside the 1.00x
    ///         tolerance so the guard prices it at par — and truncation still caps it.
    function test_TruncationCatchesWhatTheGuardPricesAtPar() public {
        _configure(MAX_DEV, FREEZE_DEV);
        _update();
        vm.roll(101);
        fast.setTick(START + 40);

        (int24 seen, bool ok, uint24 div) = ref.updateRefTick(ID);
        assertTrue(ok);
        assertEq(div, 40, "under tolerance: multiplier stays at 1.00x");
        assertEq(seen, START + int24(uint24(B)), "but the bound still applies");
    }

    /// @notice A push above the tolerance is clamped AND still raises divTicks, so the
    ///         two defences stack rather than shadowing each other.
    function test_ClampedPushStillRaisesTheMultiplierInput() public {
        _configure(MAX_DEV, FREEZE_DEV);
        _update();
        vm.roll(101);
        fast.setTick(START + 200);

        (int24 seen, bool ok, uint24 div) = ref.updateRefTick(ID);
        assertTrue(ok, "200 < 250 backstop: not frozen");
        assertGt(div, MAX_DEV, "divergence engages the graduated multiplier");
        assertEq(seen, START + int24(uint24(B)), "and the view still moves only B");
    }

    // ==================================================================
    // Admin
    // ==================================================================

    function test_OnlyOwnerCanSetTheBound() public {
        vm.prank(address(0xbad));
        vm.expectRevert(SplitV3Reference.NotOwner.selector);
        ref.setMaxTicksPerBlock(ID, 32);
    }

    function test_BoundIsPerPool() public {
        PoolId other = PoolId.wrap(bytes32(uint256(2)));
        ref.setMaxTicksPerBlock(other, 32);
        assertEq(ref.maxTicksPerBlock(ID), B);
        assertEq(ref.maxTicksPerBlock(other), 32);
    }

    // ==================================================================
    // Fuzz
    // ==================================================================

    /// @notice For any raw tick and any elapsed block count, movement never exceeds
    ///         B * blocksElapsed, and the truncated value never crosses raw.
    function testFuzz_StepNeverExceedsAllowanceAndNeverOvershoots(int24 rawTick, uint8 elapsed)
        public
    {
        vm.assume(elapsed > 0);
        vm.assume(rawTick > -800_000 && rawTick < 800_000);

        _update();
        vm.roll(100 + uint256(elapsed));
        _honestMove(rawTick);
        int24 seen = _update();

        assertLe(_absDiff(seen, START), uint256(elapsed) * B, "bounded by the allowance");
        if (rawTick >= START) assertTrue(seen <= rawTick, "must not overshoot upward");
        else                  assertTrue(seen >= rawTick, "must not overshoot downward");
    }
}
