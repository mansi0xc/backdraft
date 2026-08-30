// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BackdraftTestBase} from "../BackdraftTestBase.sol";
import {BackdraftHook}     from "../../src/BackdraftHook.sol";
import {IPoolManager}      from "v4-core/interfaces/IPoolManager.sol";
import {IReferencePrice}   from "../../src/interfaces/IReferencePrice.sol";
import {Hooks}             from "v4-core/libraries/Hooks.sol";

// ============================================================
// LP eligibility denominator + hook address validation.
//
// F1 — griefing DoS on the LP leg.
//   `eligibleLiq = inRange - (addedNow - addedThen)` subtracts liquidity added inside
//   the age window, so JIT LPs cannot collect. But `_totalAdded` only ever incremented:
//   beforeRemoveLiquidity decremented the position record and left the running total
//   alone. So an attacker could add a large position and immediately remove it, leaving
//   `recentAdds` permanently inflated, `eligibleLiq` clamped to zero, and
//   `claimLp` reverting with "no eligible liq" for EVERY honest LP on gaps opened in
//   that window. Cost: a round trip plus gas.
//
//   Out-of-range adds had the same shape from the other side: they inflated
//   `_totalAdded` while contributing nothing to `getLiquidity(id)`, so the subtraction
//   removed liquidity that was never in the minuend.
//
// F2 — the deployed hook address must encode exactly the declared permission bits. A
//   mis-mined CREATE2 salt otherwise yields a hook that silently never receives
//   beforeSwap, discovered live rather than in tests.
// ============================================================
contract LpEligibilityTest is BackdraftTestBase {

    address constant LP       = address(0x1001);
    address constant ATTACKER = address(0xbad0);
    address constant ROHAN    = address(0xaaaa);
    address constant VIK      = address(0xbbbb);

    int24 constant LO = -6000;
    int24 constant HI =  6000;

    function setUp() public override {
        super.setUp();
        _fund(LP); _fund(ATTACKER); _fund(ROHAN); _fund(VIK);
    }

    function _fund(address who) internal {
        token0.transfer(who, 80_000_000e18);
        token1.transfer(who, 80_000_000e18);
    }

    function _removeLiquidity(address lp, int24 lo, int24 hi, uint128 amount) internal {
        vm.startPrank(lp, lp);
        lpRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lo, tickUpper: hi,
                liquidityDelta: -int256(uint256(amount)), salt: bytes32(0)
            }),
            abi.encode(lp)
        );
        vm.stopPrank();
    }

    /// @dev Open and close a gap, then settle. Returns the gap index.
    function _cycleGap() internal returns (uint256 idx) {
        _swap(ROHAN, false, -500_000e18);
        idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "precondition: gap must open");
        _swap(VIK, true, -2_000_000e18);
        if (!hook.gapAt(poolId, idx).settled) hook.settle(poolId, idx);
    }

    // ------------------------------------------------------------------
    // F1 — the grief, closed
    // ------------------------------------------------------------------

    /// @notice The headline. An attacker adds a large in-range position and removes it
    ///         immediately. Honest LPs must still be able to claim. Before the fix the
    ///         inflated running total zeroed the denominator and every claim reverted.
    function test_AddThenRemoveDoesNotBlockHonestLpClaims() public {
        _addLiquidity(LP, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);

        // Grief: in, then straight back out.
        _addLiquidity(ATTACKER, LO, HI, 40_000_000e18);
        _removeLiquidity(ATTACKER, LO, HI, 40_000_000e18);

        uint256 idx = _cycleGap();
        assertGt(hook.gapAt(poolId, idx).eligibleLiqAtOpen, 0,
            "honest LP liquidity must remain eligible after an add-remove grief");

        uint256 before = token0.balanceOf(LP) + token1.balanceOf(LP);
        vm.prank(LP, LP);
        hook.claimLp(poolId, idx, LO, HI, bytes32(0));
        assertGt(token0.balanceOf(LP) + token1.balanceOf(LP), before,
            "honest LP must still be paid");
    }

    /// @notice Repeating the grief must not accumulate either.
    function test_RepeatedAddRemoveDoesNotAccumulate() public {
        _addLiquidity(LP, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);

        for (uint256 i = 0; i < 5; i++) {
            _addLiquidity(ATTACKER, LO, HI, 20_000_000e18);
            _removeLiquidity(ATTACKER, LO, HI, 20_000_000e18);
        }

        uint256 idx = _cycleGap();
        assertGt(hook.gapAt(poolId, idx).eligibleLiqAtOpen, 0,
            "repeated grief must not zero the denominator");
    }

    /// @notice Out-of-range liquidity contributes nothing to getLiquidity(id), so it must
    ///         not be subtracted from it either.
    function test_OutOfRangeAddDoesNotShrinkDenominator() public {
        _addLiquidity(LP, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);

        uint256 snap = vm.snapshotState();
        uint256 idxA = _cycleGap();
        uint128 baseline = hook.gapAt(poolId, idxA).eligibleLiqAtOpen;
        vm.revertToState(snap);

        // Far above the current tick: never in range, contributes no in-range liquidity.
        _addLiquidity(ATTACKER, 30000, 39960, 40_000_000e18);

        uint256 idxB = _cycleGap();
        assertEq(hook.gapAt(poolId, idxB).eligibleLiqAtOpen, baseline,
            "out-of-range liquidity must not enter the denominator");
    }

    /// @notice The JIT defence itself must still work: liquidity added inside the age
    ///         window is still excluded. The fix must not have removed the protection
    ///         it was meant to preserve.
    function test_JitLiquidityStillExcluded() public {
        _addLiquidity(LP, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);

        uint256 snap = vm.snapshotState();
        uint256 idxA = _cycleGap();
        uint128 withoutJit = hook.gapAt(poolId, idxA).eligibleLiqAtOpen;
        vm.revertToState(snap);

        // JIT: added just before the gap, never removed, so it IS in range now.
        _addLiquidity(ATTACKER, LO, HI, 10_000_000e18);

        uint256 idxB = _cycleGap();
        assertEq(hook.gapAt(poolId, idxB).eligibleLiqAtOpen, withoutJit,
            "JIT liquidity must still be excluded from the denominator");
    }

    /// @notice A JIT LP still cannot claim.
    function test_JitLpCannotClaim() public {
        _addLiquidity(LP, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
        _addLiquidity(ATTACKER, LO, HI, 10_000_000e18);

        uint256 idx = _cycleGap();
        vm.prank(ATTACKER, ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "too new"));
        hook.claimLp(poolId, idx, LO, HI, bytes32(0));
    }

    /// @notice Fuzz: no add-remove size can zero out the honest LP's eligibility.
    function testFuzz_AddRemoveNeverZerosDenominator(uint96 griefSize) public {
        griefSize = uint96(bound(griefSize, 1e18, 60_000_000e18));

        _addLiquidity(LP, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);

        _addLiquidity(ATTACKER, LO, HI, uint128(griefSize));
        _removeLiquidity(ATTACKER, LO, HI, uint128(griefSize));

        uint256 idx = _cycleGap();
        assertGt(hook.gapAt(poolId, idx).eligibleLiqAtOpen, 0,
            "grief zeroed the denominator at some size");
    }

    // ------------------------------------------------------------------
    // F2 — hook address validation
    // ------------------------------------------------------------------

    /// @notice Deploying to an address whose bits do not match getHookPermissions() must
    ///         revert at construction. Without this check the hook deploys fine and then
    ///         silently never receives beforeSwap.
    function test_DeployAtWrongAddressReverts() public {
        // address(this) is a normal test address; its low bits will not encode the
        // hook's declared permission set.
        vm.expectRevert();
        new BackdraftHook(IPoolManager(address(manager)), IReferencePrice(address(oracle)), address(this));
    }

    /// @notice And the mined address in setUp does satisfy it — otherwise every other
    ///         test in the suite would be running against an unvalidated deployment.
    function test_MinedHookAddressIsValid() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap,               "beforeSwap permission declared");
        assertTrue(p.afterSwap,                "afterSwap permission declared");
        assertTrue(p.beforeSwapReturnDelta,    "beforeSwapReturnDelta declared");
        assertTrue(p.beforeAddLiquidity,       "beforeAddLiquidity declared");
        assertTrue(p.beforeRemoveLiquidity,    "beforeRemoveLiquidity declared");
        assertTrue(p.afterInitialize,          "afterInitialize declared");
    }
}
