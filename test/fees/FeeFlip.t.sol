// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BackdraftTestBase} from "../BackdraftTestBase.sol";
import {BackdraftHook}     from "../../src/BackdraftHook.sol";
import {LPFeeLibrary}      from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary}      from "v4-core/libraries/StateLibrary.sol";

// ============================================================
// The fee flip — a discounted LP fee for gap-CLOSING swaps.
//
// Why it exists. The surcharge alone makes this pool a worse venue for exactly the flow
// that fixes its price: an arbitrageur's break-even widens, so the equilibrium gap sits
// WIDER here than in a vanilla pool. Capture would be funded by degrading the thing it
// measures, and "why would anyone route here" would have no answer. The flip inverts
// that — correcting flow pays a reduced LP fee, funded by the surcharge taken from the
// swaps that opened the gap, while widening flow pays full freight.
//
// The arithmetic that must stay true, asserted rather than asserted-in-a-comment:
//
//     closer  pays  surcharge − (baseFee − narrowingFee)  >  0
//     widener pays  baseFee, no surcharge
//
// Closing a gap is still MORE expensive than widening one. The discount reduces the
// penalty on correction; it does not pay anyone to correct. Inverting that would be a
// different mechanism from the one that was reviewed.
//
// Fees are measured from feeGrowthGlobal deltas and converted back to a rate in v4 fee
// units, so these tests assert the fee the POOL actually charged, not the fee the hook
// intended to ask for. A hook that returns an override v4 silently ignores — a missing
// OVERRIDE_FEE_FLAG, say — would pass an intent-based test and fail these.
// ============================================================
contract FeeFlipTest is BackdraftTestBase {

    address constant LP    = address(0x1001);
    address constant ROHAN = address(0xaaaa);   // widener
    address constant VIK   = address(0xbbbb);   // closer

    int24 constant LO = -6000;
    int24 constant HI =  6000;

    uint24 constant BASE_FEE      = 3000;   // 0.30%
    uint24 constant NARROWING_FEE = 500;    // 0.05%
    uint24 constant NO_OVERRIDE   = type(uint24).max;

    function setUp() public override {
        poolFee      = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        baseFee      = BASE_FEE;
        narrowingFee = NARROWING_FEE;

        super.setUp();
        _fund(LP); _fund(ROHAN); _fund(VIK);
        _addLiquidity(LP, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
    }

    function _fund(address who) internal {
        token0.transfer(who, 50_000_000e18);
        token1.transfer(who, 50_000_000e18);
    }

    // ------------------------------------------------------------------
    // Fee measurement
    // ------------------------------------------------------------------

    /// @dev Realised LP fee rate of a swap, in v4 fee units (hundredths of a bip).
    ///      feeGrowthGlobal rises by feeAmount * 2^128 / liquidity, so inverting gives
    ///      the fee actually taken, and dividing by the input notional gives the rate.
    function _realisedFeeRate(address who, bool zeroForOne, uint256 notional)
        internal
        returns (uint256)
    {
        uint128 liq = StateLibrary.getLiquidity(manager, poolId);
        (uint256 g0Before, uint256 g1Before) = StateLibrary.getFeeGrowthGlobals(manager, poolId);

        _swap(who, zeroForOne, -int256(notional));

        (uint256 g0After, uint256 g1After) = StateLibrary.getFeeGrowthGlobals(manager, poolId);

        // Fees are taken in the INPUT currency: currency0 for zeroForOne.
        uint256 delta = zeroForOne ? g0After - g0Before : g1After - g1Before;
        uint256 feeAmount = (delta * liq) >> 128;
        return feeAmount * 1e6 / notional;
    }

    /// @dev Rates are compared with a small tolerance: fee growth is a Q128 fixed-point
    ///      quantity and the round trip through it loses a few units.
    function _assertRateApprox(uint256 got, uint24 want, string memory err) internal pure {
        uint256 lo = uint256(want) * 995 / 1000;
        uint256 hi = uint256(want) * 1005 / 1000 + 2;
        assertGe(got, lo, err);
        assertLe(got, hi, err);
    }

    // ------------------------------------------------------------------
    // The pool really is dynamic, and really is seeded
    // ------------------------------------------------------------------

    /// @notice A dynamic-fee pool initialises with an LP fee of ZERO. Without the seed
    ///         in afterInitialize the pool would trade fee-free, and every "discount"
    ///         measured below would be a discount off nothing — passing tests,
    ///         meaningless numbers.
    function test_AfterInitializeSeedsTheDynamicBaseFee() public view {
        (,,, uint24 lpFee) = StateLibrary.getSlot0(manager, poolId);
        assertEq(lpFee, BASE_FEE, "dynamic pool must be seeded to baseFee at init");
    }

    // ------------------------------------------------------------------
    // Direction decides the fee
    // ------------------------------------------------------------------

    /// @notice The headline: with a gap open, a swap that CLOSES it is charged
    ///         narrowingFee while a swap that WIDENS it is charged baseFee.
    function test_CloserPaysNarrowingFeeWidenerPaysBaseFee() public {
        _swap(ROHAN, false, -500_000e18);
        assertGt(hook.openGapIdx(poolId), 0, "precondition: gap must open");

        uint256 widenRate = _realisedFeeRate(ROHAN, false, 100_000e18);
        _assertRateApprox(widenRate, BASE_FEE, "widening swap must pay the base fee");

        uint256 closeRate = _realisedFeeRate(VIK, true, 100_000e18);
        _assertRateApprox(closeRate, NARROWING_FEE, "closing swap must pay narrowingFee");

        assertLt(closeRate, widenRate, "closing must be cheaper on fees than widening");
    }

    /// @notice No gap open means no discount. The flip is targeted at flow that corrects
    ///         a live dislocation, not a blanket fee cut.
    function test_NoDiscountWhenNoGapIsOpen() public {
        assertEq(hook.openGapIdx(poolId), 0, "precondition: no gap");

        uint256 rate = _realisedFeeRate(VIK, true, 100_000e18);
        _assertRateApprox(rate, BASE_FEE, "calm-market swaps pay the pool's normal fee");
    }

    /// @notice Disabling the flip restores base fee on both directions — the sentinel
    ///         works, and the discount above is attributable to the override rather
    ///         than to anything else about the swap.
    function test_SentinelDisablesTheOverrideEntirely() public {
        narrowingFee = NO_OVERRIDE;
        _setPoolCfg();

        _swap(ROHAN, false, -500_000e18);
        assertGt(hook.openGapIdx(poolId), 0, "precondition: gap must open");

        uint256 closeRate = _realisedFeeRate(VIK, true, 100_000e18);
        _assertRateApprox(closeRate, BASE_FEE, "flip disabled: closer pays base fee");
    }

    /// @notice Zero is a legitimate narrowing fee — waive the LP fee entirely for
    ///         correcting flow — and must be distinguishable from "flip disabled".
    ///         The sentinel is type(uint24).max precisely so that 0 stays usable.
    function test_ZeroNarrowingFeeIsAValidConfigNotDisabled() public {
        narrowingFee = 0;
        _setPoolCfg();

        _swap(ROHAN, false, -500_000e18);
        assertGt(hook.openGapIdx(poolId), 0, "precondition: gap must open");

        (uint256 g0Before,) = StateLibrary.getFeeGrowthGlobals(manager, poolId);
        _swap(VIK, true, -100_000e18);
        (uint256 g0After,) = StateLibrary.getFeeGrowthGlobals(manager, poolId);

        assertEq(g0After, g0Before, "a zero narrowing fee must accrue no LP fee at all");
    }

    // ------------------------------------------------------------------
    // The mechanism is not inverted
    // ------------------------------------------------------------------

    /// @notice The claim the design was approved on. If the discount ever exceeded the
    ///         surcharge, the hook would pay people to trade against the pool and the
    ///         "closing costs more than widening" story would be false.
    function test_ClosingIsStillMoreExpensiveThanWidening() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);

        uint256 escrowBefore = hook.gapAt(poolId, idx).escrowed;
        _swap(VIK, true, -100_000e18);
        uint256 surcharge = hook.gapAt(poolId, idx).escrowed - escrowBefore;

        // Discount is (baseFee − narrowingFee) of notional, in v4 fee units (1e6 denom).
        uint256 discount = uint256(100_000e18) * (BASE_FEE - NARROWING_FEE) / 1e6;

        assertGt(surcharge, discount,
            "surcharge must exceed the fee discount, or closing becomes net-free");
    }

    /// @notice Same claim, swept across notionals: the surcharge scales with notional
    ///         and so does the discount, so the inequality must hold at every size
    ///         rather than at the one size the test above happens to pick.
    function testFuzz_SurchargeAlwaysExceedsDiscount(uint96 raw) public {
        uint256 notional = uint256(bound(raw, 1_000e18, 300_000e18));

        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);

        uint256 escrowBefore = hook.gapAt(poolId, idx).escrowed;
        _swap(VIK, true, -int256(notional));
        uint256 surcharge = hook.gapAt(poolId, idx).escrowed - escrowBefore;

        uint256 discount = notional * (BASE_FEE - NARROWING_FEE) / 1e6;
        assertGt(surcharge, discount, "closing must stay net-positive at every notional");
    }

    // ------------------------------------------------------------------
    // Configuration guards
    // ------------------------------------------------------------------

    /// @notice narrowingFee above baseFee would charge correcting flow MORE than normal
    ///         — a second tax on the arbitrage that fixes the price. Rejected at config
    ///         time rather than discovered as a surprising fee in production.
    function test_SetPoolCfgRejectsNarrowingFeeAboveBaseFee() public {
        narrowingFee = BASE_FEE + 1;
        vm.expectRevert(BackdraftHook.NarrowingFeeAboveBaseFee.selector);
        _setPoolCfg();
    }

    function test_SetPoolCfgRejectsBaseFeeAboveMax() public {
        baseFee = LPFeeLibrary.MAX_LP_FEE + 1;
        vm.expectRevert(BackdraftHook.BaseFeeTooHigh.selector);
        _setPoolCfg();
    }

}

/// @notice Static-fee variant of the same configuration. v4 does NOT revert when a
///         static-fee pool's hook returns an override; Hooks.beforeSwap drops it. These
///         tests therefore pin observable behaviour (surcharge still taken, fee still
///         the static one) and cannot distinguish whether the hook returned an override
///         or not. The isDynamicFee guard in _narrowingFeeOverride is not pinned by any
///         swap-level test; it is hygiene.
contract FeeFlipStaticPoolTest is BackdraftTestBase {

    address constant LP    = address(0x1001);
    address constant ROHAN = address(0xaaaa);
    address constant VIK   = address(0xbbbb);

    function setUp() public override {
        baseFee      = 3000;
        narrowingFee = 500;      // configured, but the pool is static
        super.setUp();           // poolFee left at the default static FEE
        token0.transfer(LP,    50_000_000e18); token1.transfer(LP,    50_000_000e18);
        token0.transfer(ROHAN, 50_000_000e18); token1.transfer(ROHAN, 50_000_000e18);
        token0.transfer(VIK,   50_000_000e18); token1.transfer(VIK,   50_000_000e18);
        _addLiquidity(LP, -6000, 6000, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
    }

    function test_StaticFeePoolNarrowingSwapDoesNotRevert() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "gap must open");

        // The assertion is that this does not revert, and that the surcharge still lands.
        uint256 before_ = hook.gapAt(poolId, idx).escrowed;
        _swap(VIK, true, -100_000e18);
        assertGt(hook.gapAt(poolId, idx).escrowed, before_,
            "static pool: no override, but the surcharge must still be taken");
    }

    function test_StaticFeePoolStillChargesItsStaticFee() public {
        _swap(ROHAN, false, -500_000e18);
        assertGt(hook.openGapIdx(poolId), 0, "gap must open");

        (,,, uint24 lpFee) = StateLibrary.getSlot0(manager, poolId);
        assertEq(lpFee, 3000, "static pool keeps its declared fee throughout");
    }
}
