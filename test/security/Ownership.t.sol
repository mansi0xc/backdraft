// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BackdraftTestBase}  from "../BackdraftTestBase.sol";
import {BackdraftHook}      from "../../src/BackdraftHook.sol";
import {SplitV3Reference}   from "../../src/references/SplitV3Reference.sol";
import {IReferencePrice}    from "../../src/interfaces/IReferencePrice.sol";
import {PoolId}             from "v4-core/types/PoolId.sol";

// ============================================================
// Ownership handover and admin observability.
//
// Two defects, both in the "boring" half of the contract:
//
//   Single-step ownership. `owner` was assigned once and never movable on the hook,
//   and `immutable` on the oracle — stricter than it looks, because it means a lost or
//   compromised deployer key can NEVER be rotated. That owner is not cosmetic: it can
//   repoint the reference oracle, which decides where every gap opens and how large it
//   is. Two-step transfer makes the handover provable (the nominee must sign) and
//   makes a mistyped address recoverable (nothing moves until acceptance).
//
//   Silent config changes. setPoolCfg and setReferenceOracle emitted nothing. An
//   operator swapping the oracle or changing capture rates left no on-chain trace, so
//   no monitor could alert on it and no LP could audit it after the fact. Every other
//   value-affecting action in this contract emits; these two were the exceptions.
// ============================================================
contract OwnershipTest is BackdraftTestBase {

    address constant ALICE = address(0xa11ce);
    address constant BOB   = address(0xb0b);

    event OwnerProposed(address indexed currentOwner, address indexed proposedOwner);
    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event ReferenceOracleSet(address indexed previousOracle, address indexed newOracle);
    event PoolCfgSet(PoolId indexed id, BackdraftHook.PoolCfg cfg);

    // ------------------------------------------------------------------
    // Hook: two-step handover
    // ------------------------------------------------------------------

    function test_DeployerIsOwnerAndNoPendingTransfer() public view {
        assertEq(hook.owner(), address(this));
        assertEq(hook.pendingOwner(), address(0), "no handover in flight at deploy");
    }

    function test_ProposeDoesNotTransfer() public {
        hook.proposeOwner(ALICE);
        assertEq(hook.owner(), address(this), "owner must not move on propose");
        assertEq(hook.pendingOwner(), ALICE);

        // The nominee has no powers yet.
        vm.prank(ALICE);
        vm.expectRevert(BackdraftHook.NotOwner.selector);
        hook.setRouterAllowed(BOB, true);
    }

    function test_AcceptCompletesTheTransfer() public {
        hook.proposeOwner(ALICE);
        vm.prank(ALICE);
        hook.acceptOwner();

        assertEq(hook.owner(), ALICE);
        assertEq(hook.pendingOwner(), address(0), "pending must be cleared");

        // Powers moved, and the old owner lost them.
        vm.prank(ALICE);
        hook.setRouterAllowed(BOB, true);
        assertTrue(hook.allowedRouters(BOB));

        vm.expectRevert(BackdraftHook.NotOwner.selector);
        hook.setRouterAllowed(BOB, false);
    }

    /// @notice The whole point of two-step: only the nominee can complete it, so a
    ///         transfer to an address nobody controls simply never happens.
    function test_OnlyTheNomineeCanAccept() public {
        hook.proposeOwner(ALICE);

        vm.prank(BOB);
        vm.expectRevert(BackdraftHook.NotPendingOwner.selector);
        hook.acceptOwner();

        vm.expectRevert(BackdraftHook.NotPendingOwner.selector);
        hook.acceptOwner();   // not even the current owner

        assertEq(hook.owner(), address(this), "owner unchanged after failed accepts");
    }

    function test_AcceptWithNoProposalReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(BackdraftHook.NotPendingOwner.selector);
        hook.acceptOwner();
    }

    /// @notice A mistyped nomination is recoverable precisely because it is inert.
    function test_ProposalCanBeReplacedAndCancelled() public {
        hook.proposeOwner(ALICE);
        hook.proposeOwner(BOB);
        assertEq(hook.pendingOwner(), BOB, "second proposal replaces the first");

        vm.prank(ALICE);
        vm.expectRevert(BackdraftHook.NotPendingOwner.selector);
        hook.acceptOwner();

        hook.proposeOwner(address(0));
        assertEq(hook.pendingOwner(), address(0), "zero cancels");

        vm.prank(BOB);
        vm.expectRevert(BackdraftHook.NotPendingOwner.selector);
        hook.acceptOwner();
    }

    function test_NonOwnerCannotPropose() public {
        vm.prank(ALICE);
        vm.expectRevert(BackdraftHook.NotOwner.selector);
        hook.proposeOwner(ALICE);
    }

    function test_ProposingCurrentOwnerReverts() public {
        vm.expectRevert(BackdraftHook.AlreadyOwner.selector);
        hook.proposeOwner(address(this));
    }

    /// @notice Accepting twice must not resurrect a cleared handover.
    function test_AcceptIsNotReplayable() public {
        hook.proposeOwner(ALICE);
        vm.prank(ALICE);
        hook.acceptOwner();

        vm.prank(ALICE);
        vm.expectRevert(BackdraftHook.NotPendingOwner.selector);
        hook.acceptOwner();
    }

    function testFuzz_OnlyNomineeAccepts(address caller) public {
        vm.assume(caller != ALICE && caller != address(0));
        hook.proposeOwner(ALICE);

        vm.prank(caller);
        vm.expectRevert(BackdraftHook.NotPendingOwner.selector);
        hook.acceptOwner();
        assertEq(hook.owner(), address(this));
    }

    // ------------------------------------------------------------------
    // Hook: admin observability
    // ------------------------------------------------------------------

    function test_HandoverEmits() public {
        vm.expectEmit(true, true, false, false);
        emit OwnerProposed(address(this), ALICE);
        hook.proposeOwner(ALICE);

        vm.expectEmit(true, true, false, false);
        emit OwnerTransferred(address(this), ALICE);
        vm.prank(ALICE);
        hook.acceptOwner();
    }

    /// @notice Repointing the oracle is the most consequential admin action in the
    ///         contract. It used to leave no trace at all.
    function test_SetReferenceOracleEmits() public {
        address newOracle = address(new SplitV3Reference(address(this)));

        vm.expectEmit(true, true, false, false);
        emit ReferenceOracleSet(address(oracle), newOracle);
        hook.setReferenceOracle(IReferencePrice(newOracle));
    }

    /// @notice A zero oracle would not revert — every swap would take the frozen path
    ///         and the hook would go quietly inert. Refuse it at the setter.
    function test_SetReferenceOracleRejectsZero() public {
        vm.expectRevert(BackdraftHook.OracleIsZero.selector);
        hook.setReferenceOracle(IReferencePrice(address(0)));
    }

    /// @notice The event carries the whole config, so an off-chain monitor can diff
    ///         what changed without reconstructing 16 fields from storage reads.
    function test_SetPoolCfgEmits() public {
        BackdraftHook.PoolCfg memory c = _defaultCfg();
        vm.expectEmit(true, false, false, true);
        emit PoolCfgSet(poolId, c);
        hook.setPoolCfg(poolId, c);
    }

    function test_NonOwnerCannotSetOracleOrCfg() public {
        vm.startPrank(ALICE);
        vm.expectRevert(BackdraftHook.NotOwner.selector);
        hook.setReferenceOracle(IReferencePrice(address(oracle)));
        vm.expectRevert(BackdraftHook.NotOwner.selector);
        hook.setPoolCfg(poolId, _defaultCfg());
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Oracle: same handover, previously impossible
    // ------------------------------------------------------------------

    function test_OracleOwnerIsRotatable() public {
        SplitV3Reference ref = new SplitV3Reference(address(this));
        assertEq(ref.owner(), address(this));

        ref.proposeOwner(ALICE);
        assertEq(ref.owner(), address(this), "inert until accepted");

        vm.prank(ALICE);
        ref.acceptOwner();
        assertEq(ref.owner(), ALICE);
        assertEq(ref.pendingOwner(), address(0));
    }

    function test_OracleOnlyNomineeCanAccept() public {
        SplitV3Reference ref = new SplitV3Reference(address(this));
        ref.proposeOwner(ALICE);

        vm.prank(BOB);
        vm.expectRevert(SplitV3Reference.NotPendingOwner.selector);
        ref.acceptOwner();
        assertEq(ref.owner(), address(this));
    }

    function test_OracleRejectsZeroOwnerAtDeploy() public {
        vm.expectRevert(SplitV3Reference.OwnerIsZero.selector);
        new SplitV3Reference(address(0));
    }

    // ------------------------------------------------------------------

    function _defaultCfg() internal view returns (BackdraftHook.PoolCfg memory) {
        return BackdraftHook.PoolCfg({
            guardMaxDevTicks:  50,
            divSlopeBps:       100,
            maxDivMultBps:     20_000,
            gapThresholdTicks: gapThresholdTicks,
            captureRateBps:    captureRateBps,
            surchargeCapBps:   surchargeCapBps,
            traderShareBps:    traderShareBps,
            baseFee:           3000,
            narrowingFee:      1000,
            minAgeBlocks:      minAgeBlocks,
            expiryBlocks:      expiryBlocks,
            sweepGraceBlocks:  sweepGraceBlocks
        });
    }
}
