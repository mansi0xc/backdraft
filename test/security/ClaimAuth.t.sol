// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BackdraftTestBase} from "../BackdraftTestBase.sol";
import {BackdraftHook}     from "../../src/BackdraftHook.sol";
import {PoolId}            from "v4-core/types/PoolId.sol";

// ============================================================
// Claim authorisation regression tests.
//
// History: claimLp() took `bytes32 positionKey` as a parameter and paid
// msg.sender. Every input to the key (poolId, owner, ticks, salt) is public
// or recoverable from ModifyLiquidity events, so ANY address could pass a
// real LP's key and take that LP's entire payout — and the lpClaimed flag
// then locked the real LP out permanently.
//
// The whole suite was green while this was exploitable, because no test ever
// called a claim function from an address that shouldn't be able to.
// These tests exist so that can never be true again.
// ============================================================
contract ClaimAuthTest is BackdraftTestBase {

    address constant LP     = address(0x1001);
    address constant ROHAN  = address(0xaaaa);
    address constant VIK    = address(0xbbbb);
    address constant THIEF  = address(0xdead);

    int24 constant LO = -6000;
    int24 constant HI =  6000;

    function setUp() public override {
        super.setUp();
        _fund(LP);
        _fund(ROHAN);
        _fund(VIK);
        _fund(THIEF);
    }

    function _fund(address who) internal {
        token0.transfer(who, 50_000_000e18);
        token1.transfer(who, 50_000_000e18);
    }

    /// @dev Build a settled gap with a non-zero LP pot and an eligible LP.
    ///      Asserts its own preconditions — no silent `return` escape hatches.
    function _settledGapWithLpPot() internal returns (uint256 gapIdx) {
        _addLiquidity(LP, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);

        _swap(ROHAN, false, -500_000e18);          // open the gap
        gapIdx = hook.openGapIdx(poolId);
        assertGt(gapIdx, 0, "precondition: gap must open");

        _swap(VIK, true, -2_000_000e18);           // close it, paying surcharge

        uint128 escrowed = hook.gapAt(poolId, gapIdx).escrowed;
        assertGt(escrowed, 0, "precondition: surcharge must be escrowed");

        hook.settle(poolId, gapIdx);
        assertTrue(hook.gapAt(poolId, gapIdx).settled, "precondition: gap must settle");
    }

    // ------------------------------------------------------------------
    // The exploit, now closed
    // ------------------------------------------------------------------

    /// @notice A non-LP calling claimLp with the LP's exact position parameters
    ///         must get nothing. Under the old signature this address received
    ///         the LP's whole payout.
    function test_ThiefCannotClaimAnotherLpsPayout() public {
        uint256 gapIdx = _settledGapWithLpPot();

        uint256 t0 = token0.balanceOf(THIEF);
        uint256 t1 = token1.balanceOf(THIEF);

        // THIEF supplies LP's exact tick range and salt. The key is now derived
        // from msg.sender, so this resolves to THIEF's own (empty) position.
        vm.prank(THIEF, THIEF);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "no position"));
        hook.claimLp(poolId, gapIdx, LO, HI, bytes32(0));

        assertEq(token0.balanceOf(THIEF), t0, "thief must not gain currency0");
        assertEq(token1.balanceOf(THIEF), t1, "thief must not gain currency1");
    }

    /// @notice The real LP is still paid, and is NOT locked out by a prior
    ///         attempt from someone else. This is the half that made the old bug
    ///         unrecoverable rather than merely lossy.
    function test_RealLpStillPaidAfterThiefAttempt() public {
        uint256 gapIdx = _settledGapWithLpPot();

        vm.prank(THIEF, THIEF);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "no position"));
        hook.claimLp(poolId, gapIdx, LO, HI, bytes32(0));

        uint256 before0 = token0.balanceOf(LP);
        uint256 before1 = token1.balanceOf(LP);

        vm.prank(LP, LP);
        hook.claimLp(poolId, gapIdx, LO, HI, bytes32(0));

        uint256 gained = (token0.balanceOf(LP) - before0) + (token1.balanceOf(LP) - before1);
        assertGt(gained, 0, "real LP must still be paid after a failed theft attempt");
    }

    /// @notice Double-claim by the rightful owner still reverts.
    function test_LpCannotClaimTwice() public {
        uint256 gapIdx = _settledGapWithLpPot();

        vm.prank(LP, LP);
        hook.claimLp(poolId, gapIdx, LO, HI, bytes32(0));

        vm.prank(LP, LP);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "claimed"));
        hook.claimLp(poolId, gapIdx, LO, HI, bytes32(0));
    }

    /// @notice An LP cannot claim against a tick range it never opened.
    function test_LpCannotClaimForeignTickRange() public {
        uint256 gapIdx = _settledGapWithLpPot();

        vm.prank(LP, LP);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "no position"));
        hook.claimLp(poolId, gapIdx, int24(-1200), int24(1200), bytes32(0));
    }

    /// @notice An LP cannot claim against a salt it never used.
    function test_LpCannotClaimForeignSalt() public {
        uint256 gapIdx = _settledGapWithLpPot();

        vm.prank(LP, LP);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "no position"));
        hook.claimLp(poolId, gapIdx, LO, HI, bytes32(uint256(1)));
    }

    /// @notice claimTrader is keyed on msg.sender already — pin that behaviour so a
    ///         future refactor cannot regress it the way claimLp did.
    function test_NonContributorCannotClaimTraderPot() public {
        _addLiquidity(LP, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);

        _swap(ROHAN, false, -500_000e18);
        uint256 gapIdx = hook.openGapIdx(poolId);
        assertGt(gapIdx, 0, "precondition: gap must open");

        _swap(ROHAN, false, -200_000e18);          // credited widening
        _swap(VIK,   true,  -2_000_000e18);        // close + surcharge
        hook.settle(poolId, gapIdx);

        assertGt(hook.gapAt(poolId, gapIdx).totalContribution, 0,
            "precondition: ledger must be non-empty");

        vm.prank(THIEF, THIEF);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "nothing"));
        hook.claimTrader(poolId, gapIdx);
    }

    /// @notice Fuzz: no address other than LP can ever extract value via claimLp.
    function testFuzz_OnlyPositionOwnerCanClaim(address caller) public {
        vm.assume(caller != LP);
        vm.assume(caller != address(0));
        vm.assume(caller.code.length == 0);
        vm.assume(caller != address(manager) && caller != address(hook));

        uint256 gapIdx = _settledGapWithLpPot();

        uint256 b0 = token0.balanceOf(caller);
        uint256 b1 = token1.balanceOf(caller);

        vm.prank(caller, caller);
        try hook.claimLp(poolId, gapIdx, LO, HI, bytes32(0)) {
            // A successful call is only acceptable if it moved no value.
            assertEq(token0.balanceOf(caller), b0, "non-owner gained currency0");
            assertEq(token1.balanceOf(caller), b1, "non-owner gained currency1");
        } catch {
            // Reverting is the expected path.
        }
    }
}
