// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {FullMath}     from "v4-core/libraries/FullMath.sol";

/// @title FeeFlipMath
/// @notice The LP-fee discount granted to a gap-narrowing swap.
/// @dev Extracted from BackdraftHook so it can be tested directly. The hook cannot be
///      deployed at an arbitrary address (Hooks.validateHookAddress), so a test harness
///      subclassing it is impractical, and swap-level tests can only observe the fee the
///      pool ENDED UP charging — they cannot distinguish "the hook returned no override"
///      from "the hook returned one and v4 dropped it". A pure library can be asserted
///      on directly, which is what pins the isDynamicFee guard.
library FeeFlipMath {
    /// @dev Sentinel: the flip is off. Not a valid v4 fee.
    uint24 internal constant NO_FEE_OVERRIDE = type(uint24).max;

    /// @notice Fee override for a narrowing swap, or 0 for "no override, pool fee applies".
    ///
    /// The discount is bounded by the surcharge taken from the same swap. Unbounded, a
    /// 3000 -> 500 flip is 25 bps against a 5 bps surcharge at a 100-tick gap, so a
    /// closer paid ~10 bps all-in against a widener's 30 and LPs came out behind a
    /// vanilla pool on the pure LVR path (review 2026-09-03, R4).
    ///
    /// v4 charges its LP fee on what reaches the pool, which is `notional - surcharge`.
    /// For "the closer pays at least `baseFee` on the full notional" to hold exactly:
    ///
    ///     s + (n - s)(b - d) >= n*b   <=>   d <= s(1 - b) / (n - s)
    ///
    /// in v4 fee units (1e6 = 100%). mulDiv floors, so the bound is never exceeded.
    /// Below the cap the discount rebates the surcharge exactly and the closer pays what
    /// a vanilla pool would; above it, the full `narrowingFee` applies and the surcharge
    /// dominates. Closing is never cheaper than widening.
    function narrowingFeeOverride(
        uint24  poolFee,
        uint24  baseFee,
        uint24  narrowingFee,
        uint256 surcharge,
        uint256 notional
    ) internal pure returns (uint24) {
        if (narrowingFee == NO_FEE_OVERRIDE) return 0;

        // v4 does not revert when a static-fee pool's hook returns an override — it
        // silently drops it (Hooks.beforeSwap only parses the fee when the key's fee
        // carries the dynamic flag). Returning 0 keeps the value honest about what the
        // pool will do with it, which is nothing.
        if (!LPFeeLibrary.isDynamicFee(poolFee)) return 0;

        // No surcharge funds no discount.
        if (surcharge == 0 || surcharge >= notional) return 0;

        uint256 discountCap  = FullMath.mulDiv(surcharge, 1e6 - uint256(baseFee), notional - surcharge);
        uint256 fullDiscount = uint256(baseFee) - uint256(narrowingFee);
        uint256 discount     = discountCap < fullDiscount ? discountCap : fullDiscount;
        return uint24(uint256(baseFee) - discount) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }
}
