// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BackdraftTestBase} from "../BackdraftTestBase.sol";
import {BackdraftHook}     from "../../src/BackdraftHook.sol";

// ============================================================
// Gap lifecycle: expiry on the swap path, and settle-on-close.
//
// Two defects, both about a gap that should be over but isn't:
//
//   Expiry was never read on the swap path. beforeSwap surcharged whenever
//   openGapIdx != 0, and afterSwap closed only on threshold or sign flip. A gap whose
//   dislocation vanished because the REFERENCE moved back — with no swap in this pool,
//   which the hook never observes — stayed open indefinitely. The next swap that
//   happened to be narrowing against a tiny residual paid the FULL maxAbsGap peak rate.
//   One innocent trader eating a stale surcharge, arbitrarily long after the fact.
//
//   _closeGap did not settle, and settle() is permissionless with no caller reward.
//   Nobody had any reason to call it, and both claim functions require g.settled — so
//   in practice escrow would be collected, gaps would close, and nothing would ever be
//   claimable. The whole payout half of the mechanism depended on an altruistic keeper.
// ============================================================
contract GapLifecycleTest is BackdraftTestBase {

    address constant LP     = address(0x1001);
    address constant ROHAN  = address(0xaaaa);
    address constant VIK    = address(0xbbbb);
    address constant RETAIL = address(0xcccc);

    int24 constant LO = -6000;
    int24 constant HI =  6000;

    function setUp() public override {
        super.setUp();
        _fund(LP); _fund(ROHAN); _fund(VIK); _fund(RETAIL);
        _addLiquidity(LP, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
    }

    function _fund(address who) internal {
        token0.transfer(who, 80_000_000e18);
        token1.transfer(who, 80_000_000e18);
    }

    // ------------------------------------------------------------------
    // Expiry
    // ------------------------------------------------------------------

    /// @notice An expired gap must stop charging. Before the fix this swapper paid the
    ///         full peak rate on a gap that had been over for a thousand blocks.
    function test_ExpiredGapDoesNotSurcharge() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "precondition: gap must open");

        uint128 escrowedAtExpiry = hook.gapAt(poolId, idx).escrowed;

        // The reference catches up with the pool: the dislocation is gone, but no swap
        // has occurred, so the hook has never been told.
        oracle.setRef(poolId, _poolTick());
        vm.roll(block.number + expiryBlocks + 1);

        _swap(RETAIL, true, -100_000e18);

        assertEq(hook.gapAt(poolId, idx).escrowed, escrowedAtExpiry,
            "expired gap must not collect from a later swapper");
    }

    /// @notice And the expired gap leaves the open slot, so a genuinely new dislocation
    ///         opens a fresh gap instead of being absorbed by the stale record.
    function test_ExpiredGapIsClearedFromOpenSlot() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);

        oracle.setRef(poolId, _poolTick());
        vm.roll(block.number + expiryBlocks + 1);
        _swap(RETAIL, true, -100_000e18);

        assertTrue(hook.openGapIdx(poolId) != idx, "expired gap must leave the open slot");
    }

    /// @notice A gap still inside its window must be unaffected — expiry must not become
    ///         an early exit from the mechanism.
    function test_UnexpiredGapStillSurcharges() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        uint128 before = hook.gapAt(poolId, idx).escrowed;

        vm.roll(block.number + 1);
        _swap(VIK, true, -200_000e18);

        assertGt(hook.gapAt(poolId, idx).escrowed, before,
            "a live gap must still surcharge its closer");
    }

    /// @notice Expiry must not silently discard escrow already collected — the gap ends,
    ///         the money stays claimable.
    function test_ExpiredGapKeepsItsEscrowClaimable() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        _swap(VIK, true, -200_000e18);           // partial close, pays a surcharge
        uint128 escrowed = hook.gapAt(poolId, idx).escrowed;
        assertGt(escrowed, 0, "precondition: escrow collected");

        oracle.setRef(poolId, _poolTick());
        vm.roll(block.number + expiryBlocks + 1);
        _swap(RETAIL, true, -50_000e18);         // trips the expiry close

        assertEq(hook.gapAt(poolId, idx).escrowed, escrowed, "escrow must survive expiry");
        assertTrue(hook.gapAt(poolId, idx).settled, "expiry close must settle");

        uint256 before = token0.balanceOf(LP) + token1.balanceOf(LP);
        vm.prank(LP, LP);
        hook.claimLp(poolId, idx, LO, HI, bytes32(0));
        assertGt(token0.balanceOf(LP) + token1.balanceOf(LP), before,
            "LP must still be paid from an expired gap");
    }

    /// @notice THE discriminating test for expiry. The others move the reference all the
    ///         way back, so the later swap is not narrowing and pays nothing whether or
    ///         not expiry is checked — they pass against the broken code too.
    ///
    ///         Here a RESIDUAL gap is left above threshold. Without the expiry check the
    ///         stale gap is still open and the swap is priced on its maxAbsGap peak
    ///         (~970 ticks). With it, the stale gap closes and a fresh one opens on the
    ///         residual (~100 ticks), so the same swapper pays roughly a tenth as much.
    ///         That difference is the whole point of the fix: nobody should be charged
    ///         the peak rate of a dislocation that ended long ago.
    function test_ExpiredGapDoesNotChargeStalePeakRate() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 staleIdx = hook.openGapIdx(poolId);
        assertGt(staleIdx, 0, "precondition: gap must open");

        uint24 stalePeak = hook.gapAt(poolId, staleIdx).maxAbsGap;
        assertGt(stalePeak, 500, "precondition: a large peak to go stale");

        // Reference moves most of the way back, leaving a small live dislocation.
        oracle.setRef(poolId, _poolTick() - 100);
        vm.roll(block.number + expiryBlocks + 1);

        uint128 staleEscrowBefore = hook.gapAt(poolId, staleIdx).escrowed;
        uint256 c0Before = _hookBalance(poolKey.currency0);
        uint256 c1Before = _hookBalance(poolKey.currency1);

        _swap(RETAIL, true, -100_000e18);

        // The decisive assertion: the expired gap must not collect one more wei. Under
        // the broken code it collects here, priced on a peak that ended long ago.
        assertEq(hook.gapAt(poolId, staleIdx).escrowed, staleEscrowBefore,
            "expired gap collected from a later swapper at its stale peak rate");

        // The swapper may still pay — a live 100-tick dislocation is real — but it must
        // be priced on that, roughly a tenth of the stale peak.
        uint256 charged = (_hookBalance(poolKey.currency0) - c0Before)
                        + (_hookBalance(poolKey.currency1) - c1Before);
        uint256 stalePeakCharge = 100_000e18 * uint256(stalePeak) * captureRateBps / 1e8;
        assertLt(charged, stalePeakCharge / 2,
            "swap was priced against a stale peak instead of the live gap");
    }

    // ------------------------------------------------------------------
    // Settle on close
    // ------------------------------------------------------------------

    /// @notice Closing a gap settles it.
    function test_ClosingAGapSettlesIt() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        _swap(VIK, true, -2_000_000e18);

        assertTrue(hook.gapAt(poolId, idx).settled, "closing must settle");
    }

    /// @notice The headline: the full cycle must be claimable with no keeper in the loop.
    ///         There is deliberately no hook.settle() call anywhere in this test.
    function test_ClaimsWorkWithoutAnyoneCallingSettle() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        _swap(ROHAN, false, -200_000e18);
        _swap(VIK, true, -2_000_000e18);

        uint256 rBefore = token0.balanceOf(ROHAN) + token1.balanceOf(ROHAN);
        vm.prank(ROHAN, ROHAN);
        hook.claimTrader(poolId, idx);
        assertGt(token0.balanceOf(ROHAN) + token1.balanceOf(ROHAN), rBefore,
            "originator must be able to claim without a keeper");

        uint256 lBefore = token0.balanceOf(LP) + token1.balanceOf(LP);
        vm.prank(LP, LP);
        hook.claimLp(poolId, idx, LO, HI, bytes32(0));
        assertGt(token0.balanceOf(LP) + token1.balanceOf(LP), lBefore,
            "LP must be able to claim without a keeper");
    }

    /// @notice settle() must still work for a gap that expires while still open — the
    ///         keeper path remains available, it is simply no longer required.
    function test_SettleStillWorksForExpiredOpenGap() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);

        vm.roll(block.number + expiryBlocks + 1);
        hook.settle(poolId, idx);

        assertTrue(hook.gapAt(poolId, idx).settled, "expired open gap must still settle");
    }

    /// @notice Settling twice reverts, whichever route settled it first.
    function test_SettleAfterAutoSettleReverts() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        _swap(VIK, true, -2_000_000e18);

        vm.expectRevert(abi.encodeWithSignature("Error(string)", "already settled"));
        hook.settle(poolId, idx);
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    /// @notice However long a gap is left, a later swapper never pays for it once expired.
    function testFuzz_ExpiredGapNeverCharges(uint32 extraBlocks) public {
        extraBlocks = uint32(bound(extraBlocks, 1, 100_000));

        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        uint128 atExpiry = hook.gapAt(poolId, idx).escrowed;

        oracle.setRef(poolId, _poolTick());
        vm.roll(block.number + expiryBlocks + extraBlocks);
        _swap(RETAIL, true, -100_000e18);

        assertEq(hook.gapAt(poolId, idx).escrowed, atExpiry,
            "expired gap charged a later swapper");
    }
}
