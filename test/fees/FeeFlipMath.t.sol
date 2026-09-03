// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test}         from "forge-std/Test.sol";
import {FeeFlipMath}  from "../../src/libraries/FeeFlipMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

/// @notice Direct unit tests for the narrowing-fee discount.
///
/// The swap-level FeeFlip suite can only observe the fee the POOL ended up charging, so
/// it cannot tell "the hook returned no override" apart from "the hook returned one and
/// v4 dropped it" — v4 silently discards an override from a static-fee pool rather than
/// reverting. A mutation deleting the isDynamicFee guard therefore survived every
/// swap-level test. These assert on the returned value itself (review 2026-09-03).
contract FeeFlipMathTest is Test {
    uint24 constant DYNAMIC = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    uint24 constant STATIC  = 3000;
    uint24 constant BASE    = 3000;   // 0.30%
    uint24 constant NARROW  = 500;    // 0.05%

    function _fee(uint24 v) internal pure returns (uint24) {
        return v & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }

    // ---------------------------------------------------------------- guards

    function test_DisabledSentinelReturnsNoOverride() public pure {
        uint24 v = FeeFlipMath.narrowingFeeOverride(
            DYNAMIC, BASE, FeeFlipMath.NO_FEE_OVERRIDE, 100e18, 100_000e18
        );
        assertEq(v, 0, "NO_FEE_OVERRIDE disables the flip");
    }

    /// @notice The guard a swap-level test cannot see.
    function test_StaticFeePoolReturnsNoOverride() public pure {
        uint24 v = FeeFlipMath.narrowingFeeOverride(STATIC, BASE, NARROW, 100e18, 100_000e18);
        assertEq(v, 0, "no override for a pool that cannot use one");
    }

    function test_DynamicFeePoolReturnsAnOverride() public pure {
        uint24 v = FeeFlipMath.narrowingFeeOverride(DYNAMIC, BASE, NARROW, 100e18, 100_000e18);
        assertTrue(v & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0, "override flag set");
    }

    function test_ZeroSurchargeFundsNoDiscount() public pure {
        uint24 v = FeeFlipMath.narrowingFeeOverride(DYNAMIC, BASE, NARROW, 0, 100_000e18);
        assertEq(v, 0, "nothing to rebate");
    }

    /// @dev Degenerate input: the hook never produces surcharge >= notional (the cap is
    ///      bounded at 100%), but the library must not underflow if it ever did.
    function test_SurchargeAtOrAboveNotionalReturnsNoOverride() public pure {
        assertEq(FeeFlipMath.narrowingFeeOverride(DYNAMIC, BASE, NARROW, 100e18, 100e18), 0);
        assertEq(FeeFlipMath.narrowingFeeOverride(DYNAMIC, BASE, NARROW, 200e18, 100e18), 0);
        assertEq(FeeFlipMath.narrowingFeeOverride(DYNAMIC, BASE, NARROW, 1, 0), 0);
    }

    // ---------------------------------------------------------------- bound

    /// @notice Small surcharge: the discount rebates it exactly and stops there.
    function test_SmallSurchargeGetsAPartialDiscount() public pure {
        uint256 n = 100_000e18;
        uint256 s = n * 5 / 1e4;                       // 5 bps
        uint24  f = _fee(FeeFlipMath.narrowingFeeOverride(DYNAMIC, BASE, NARROW, s, n));
        assertGt(f, NARROW, "not the full discount");
        assertLt(f, BASE,   "but some discount");
    }

    /// @notice Large surcharge: the cap does not bind and the full narrowingFee applies.
    function test_LargeSurchargeGetsTheFullDiscount() public pure {
        uint256 n = 100_000e18;
        uint256 s = n * 200 / 1e4;                     // 200 bps, the cap regime
        uint24  f = _fee(FeeFlipMath.narrowingFeeOverride(DYNAMIC, BASE, NARROW, s, n));
        assertEq(f, NARROW, "full discount");
    }

    /// @notice The discount is monotone in the surcharge: paying more never buys less.
    function test_DiscountIsMonotoneInSurcharge() public pure {
        uint256 n = 100_000e18;
        uint24 prev = type(uint24).max;
        for (uint256 bps = 1; bps <= 300; bps += 7) {
            uint24 f = _fee(FeeFlipMath.narrowingFeeOverride(DYNAMIC, BASE, NARROW, n * bps / 1e4, n));
            assertLe(f, prev, "fee must not rise as the surcharge rises");
            prev = f;
        }
    }

    /// @notice The invariant the bound exists to guarantee: a closer's total cost — the
    ///         surcharge plus the LP fee on what reaches the pool — is never less than
    ///         `baseFee` on the full notional.
    function testFuzz_CloserNeverPaysLessThanBaseFee(uint96 rawN, uint96 rawS, uint24 rawBase)
        public
        pure
    {
        uint256 n    = bound(rawN, 1e12, type(uint96).max);
        uint256 s    = bound(rawS, 1, n - 1);
        uint24  base = uint24(bound(rawBase, 1, LPFeeLibrary.MAX_LP_FEE));
        uint24  narrow = base / 6;

        uint24 v = FeeFlipMath.narrowingFeeOverride(DYNAMIC, base, narrow, s, n);
        uint24 fee = v == 0 ? base : _fee(v);
        assertLe(fee, base, "the flip never RAISES the fee");

        uint256 closer  = s + ((n - s) * fee) / 1e6;
        uint256 widener = (n * base) / 1e6;
        assertGe(closer, widener, "closing must never be cheaper than widening");
    }

    /// @notice The returned value is a well-formed v4 fee: override flag set, and the
    ///         fee itself inside MAX_LP_FEE.
    function testFuzz_ReturnsAWellFormedFee(uint96 rawN, uint96 rawS) public pure {
        uint256 n = bound(rawN, 1e12, type(uint96).max);
        uint256 s = bound(rawS, 1, n - 1);
        uint24  v = FeeFlipMath.narrowingFeeOverride(DYNAMIC, BASE, NARROW, s, n);
        if (v == 0) return;
        assertTrue(v & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0, "override flag");
        uint24 fee = _fee(v);
        assertLe(fee, LPFeeLibrary.MAX_LP_FEE, "inside the v4 fee range");
        assertGe(fee, NARROW, "never below narrowingFee");
        assertLe(fee, BASE,   "never above baseFee");
    }
}
