// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BackdraftTestBase} from "../BackdraftTestBase.sol";
import {BackdraftHook}     from "../../src/BackdraftHook.sol";
import {IPoolManager}      from "v4-core/interfaces/IPoolManager.sol";

// ============================================================
// Per-gap payout cap + unclaimed sweep.
//
// The bug: claimLp computed
//
//     owed = lpPot * p.liquidity / eligibleLiqAtOpen
//
// with nothing bounding the SUM of those claims. `eligibleLiqAtOpen` comes from
// pool-wide in-range liquidity minus recent adds; claims come from each eligible
// position's own `p.liquidity`. Two different quantities, no structural guarantee that
// the second is bounded by the first.
//
// They diverge without malice. An LP who adds in-range inside the lookback window, and
// whose range then falls OUT of range before the gap opens, is subtracted from the
// denominator while contributing nothing to the numerator. 10M of eligible liquidity
// against a 5M denominator pays 200% of the pot.
//
// Escrow is one undifferentiated ERC-6909 balance, so an over-claim on one gap is paid
// out of OTHER gaps' escrow — a cross-gap solvency leak, not a local rounding problem.
//
// The mirror problem is stranded funds: when the denominator EXCEEDS the claimants
// (out-of-range liquidity at open, positions added through a non-allowlisted router,
// LPs who simply never claim) the remainder had no owner and no route out of the
// contract. sweepUnclaimed donates it back into the pool, which credits current in-range
// LPs. No treasury, no owner withdrawal, nothing to trust.
// ============================================================
contract PayoutCapTest is BackdraftTestBase {

    address constant LP_A  = address(0x1001);   // long-standing, in range
    address constant LP_D  = address(0x1002);   // adds in-range, then goes out of range
    address constant ROHAN = address(0xaaaa);
    address constant VIK   = address(0xbbbb);
    address constant ANYONE = address(0x9999);

    int24 constant LO = -6000;
    int24 constant HI =  6000;

    function setUp() public override {
        super.setUp();
        _fund(LP_A); _fund(LP_D); _fund(ROHAN); _fund(VIK);
    }

    function _fund(address who) internal {
        token0.transfer(who, 80_000_000e18);
        token1.transfer(who, 80_000_000e18);
    }

    function _cycleGap() internal returns (uint256 idx) {
        _swap(ROHAN, false, -500_000e18);
        idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "precondition: gap must open");
        _swap(VIK, true, -2_000_000e18);
        // Extra liquidity in the pool can leave a residual above threshold, so fall back
        // to expiry rather than skipping the assertion this helper exists to set up.
        if (hook.openGapIdx(poolId) == idx) {
            vm.roll(block.number + expiryBlocks + 1);
        }
        if (!hook.gapAt(poolId, idx).settled) hook.settle(poolId, idx);
    }

    // ------------------------------------------------------------------
    // The cap
    // ------------------------------------------------------------------

    /// @notice Total LP payouts on a gap may never exceed that gap's LP pot, whatever
    ///         the denominator says. Constructed so the denominator is deflated relative
    ///         to the claimants.
    function test_LpClaimsCannotExceedTheGapPot() public {
        _addLiquidity(LP_A, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);

        // LP_D adds in-range inside the lookback window, in a NARROW band the price will
        // leave. Subtracted from the denominator; contributes nothing to the numerator.
        _addLiquidity(LP_D, -120, 120, 5_000_000e18);

        uint256 idx = _cycleGap();
        BackdraftHook.Gap memory g = hook.gapAt(poolId, idx);
        uint256 lpPot = uint256(g.escrowed) - (uint256(g.escrowed) * traderShareBps / 10_000);

        uint256 hookBefore = _hookBalance(g.isCurrency0 ? poolKey.currency0 : poolKey.currency1);

        vm.prank(LP_A, LP_A);
        hook.claimLp(poolId, idx, LO, HI, bytes32(0));

        uint256 paidOut = hookBefore
            - _hookBalance(g.isCurrency0 ? poolKey.currency0 : poolKey.currency1);

        assertLe(paidOut, lpPot + 1, "LP payout exceeded this gap's pot");
        assertLe(hook.gapAt(poolId, idx).lpPaid, lpPot + 1, "lpPaid exceeded the pot");
    }

    /// @notice One gap's claims must never be funded from another gap's escrow. Runs two
    ///         full gap cycles and checks the hook still holds enough for the second.
    function test_OneGapCannotDrainAnothersEscrow() public {
        _addLiquidity(LP_A, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);

        uint256 idx1 = _cycleGap();
        vm.roll(block.number + 5);
        _addLiquidity(LP_D, -120, 120, 5_000_000e18);
        uint256 idx2 = _cycleGap();

        assertTrue(idx1 != idx2, "precondition: two distinct gaps");

        vm.prank(LP_A, LP_A);
        hook.claimLp(poolId, idx2, LO, HI, bytes32(0));

        BackdraftHook.Gap memory g1 = hook.gapAt(poolId, idx1);
        uint256 held = _hookBalance(g1.isCurrency0 ? poolKey.currency0 : poolKey.currency1);
        assertGe(held, uint256(g1.escrowed) - uint256(g1.lpPaid) - uint256(g1.traderPaid),
            "gap 1's escrow was consumed by a claim against gap 2");
    }

    /// @notice The normal case must be unaffected: a sole eligible LP still receives
    ///         essentially the whole pot. The cap must bound abuse, not ordinary payouts.
    function test_SoleLpStillReceivesFullPot() public {
        _addLiquidity(LP_A, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);

        uint256 idx = _cycleGap();
        BackdraftHook.Gap memory g = hook.gapAt(poolId, idx);
        uint256 lpPot = uint256(g.escrowed) - (uint256(g.escrowed) * traderShareBps / 10_000);

        uint256 before = token0.balanceOf(LP_A) + token1.balanceOf(LP_A);
        vm.prank(LP_A, LP_A);
        hook.claimLp(poolId, idx, LO, HI, bytes32(0));
        uint256 gained = (token0.balanceOf(LP_A) + token1.balanceOf(LP_A)) - before;

        assertApproxEqAbs(gained, lpPot, 2, "sole eligible LP must still get the pot");
    }

    // ------------------------------------------------------------------
    // The sweep
    // ------------------------------------------------------------------

    /// @notice Unclaimed remainder returns to LPs, and only after expiry plus grace.
    function test_SweepReturnsRemainderAfterGrace() public {
        _addLiquidity(LP_A, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
        uint256 idx = _cycleGap();

        // Nobody claims.
        vm.roll(block.number + expiryBlocks + sweepGraceBlocks + 1);

        BackdraftHook.Gap memory g = hook.gapAt(poolId, idx);
        uint256 hookBefore = _hookBalance(g.isCurrency0 ? poolKey.currency0 : poolKey.currency1);
        assertGt(hookBefore, 0, "precondition: hook holds escrow");

        vm.prank(ANYONE, ANYONE);
        hook.sweepUnclaimed(poolId, idx);

        assertLt(
            _hookBalance(g.isCurrency0 ? poolKey.currency0 : poolKey.currency1), hookBefore,
            "sweep must move the remainder out of the hook"
        );
        assertTrue(hook.gapAt(poolId, idx).swept, "gap must be marked swept");
    }

    function test_SweepRevertsBeforeGrace() public {
        _addLiquidity(LP_A, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
        uint256 idx = _cycleGap();

        vm.prank(ANYONE, ANYONE);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "too early"));
        hook.sweepUnclaimed(poolId, idx);
    }

    function test_SweepCannotRunTwice() public {
        _addLiquidity(LP_A, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
        uint256 idx = _cycleGap();
        vm.roll(block.number + expiryBlocks + sweepGraceBlocks + 1);

        vm.prank(ANYONE, ANYONE);
        hook.sweepUnclaimed(poolId, idx);

        vm.prank(ANYONE, ANYONE);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "swept"));
        hook.sweepUnclaimed(poolId, idx);
    }

    /// @notice A sweep must not take money an LP has already earned but not yet claimed
    ///         — the grace window is the LP's protection, and the sweep only takes what
    ///         is left after it.
    function test_SweepOnlyTakesWhatIsLeft() public {
        _addLiquidity(LP_A, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
        uint256 idx = _cycleGap();

        vm.prank(LP_A, LP_A);
        hook.claimLp(poolId, idx, LO, HI, bytes32(0));
        uint128 paid = hook.gapAt(poolId, idx).lpPaid;
        assertGt(paid, 0, "precondition: LP claimed");

        vm.roll(block.number + expiryBlocks + sweepGraceBlocks + 1);
        vm.prank(ANYONE, ANYONE);
        hook.sweepUnclaimed(poolId, idx);

        assertEq(hook.gapAt(poolId, idx).lpPaid, paid, "sweep must not alter what was paid");
    }

    /// @notice Fuzz: across arbitrary out-of-range band sizes, LP payouts stay inside
    ///         the gap's pot.
    function testFuzz_LpPaidNeverExceedsPot(uint96 strandedSize) public {
        strandedSize = uint96(bound(strandedSize, 1e18, 40_000_000e18));

        _addLiquidity(LP_A, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
        _addLiquidity(LP_D, -120, 120, uint128(strandedSize));

        uint256 idx = _cycleGap();
        BackdraftHook.Gap memory g = hook.gapAt(poolId, idx);
        uint256 lpPot = uint256(g.escrowed) - (uint256(g.escrowed) * traderShareBps / 10_000);

        vm.prank(LP_A, LP_A);
        try hook.claimLp(poolId, idx, LO, HI, bytes32(0)) {} catch {}

        assertLe(hook.gapAt(poolId, idx).lpPaid, lpPot + 1, "lpPaid exceeded the pot");
    }
}
