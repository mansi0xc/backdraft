// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";

library SurchargeMath {
    /// @notice Surcharge = notional × gapTicks × rateBps, capped at notional × capBps.
    /// @param notional   Absolute swap amount, in the currency the surcharge is taken in
    /// @param gapTicks   |poolTick − refTick| the swap is priced against (maxAbsGap)
    /// @param rateBps    captureRateBps — basis points of surcharge per tick of gap
    /// @param capBps     Hard ceiling on the surcharge rate, in basis points
    /// @return surcharge Token amount to collect from the swapper
    ///
    /// @dev The previous implementation collapsed the rate to an integer number of basis
    ///      points BEFORE applying it:
    ///
    ///          bps = gapTicks * rateBps / 10_000;      // integer division
    ///          return notional * bps / 10_000;
    ///
    ///      That truncation is not a rounding detail, it is a step function where the
    ///      design assumes a slope, and it lands hardest exactly at the gaps the hook
    ///      exists to price. Measured, notional = 1e18, cap = 200:
    ///
    ///          gap  rate        old              new
    ///           66   100          0    66_000_000_000_000     <- ZERO surcharge
    ///           99   100          0    99_000_000_000_000     <- ZERO surcharge
    ///          100   100    1.00e14           1.00e14
    ///          150   100    1.00e14           1.50e14         <- 33% undercharge
    ///           60   500    3.00e14           3.00e14
    ///           65   500    3.00e14           3.25e14
    ///           79   500    3.00e14           3.95e14         <- gaps 60..79 identical
    ///
    ///      With captureRateBps = 100 nothing at all is collected until the gap reaches
    ///      100 ticks — above gapThresholdTicks = 65, so the hook would open gaps,
    ///      escrow nothing, and settle empty pots. The test suite never saw it because
    ///      the harness uses captureRateBps = 500 and scenarios large enough to bind the
    ///      cap, which is the one region where old and new agree.
    ///
    ///      The fix keeps full precision to the final division. FullMath.mulDiv carries a
    ///      512-bit intermediate, so notional × gapTicks × rateBps cannot overflow on the
    ///      way: gapTicks × rateBps is at most 2^24 × 2^16 = 2^40.
    function compute(uint256 notional, uint24 gapTicks, uint16 rateBps, uint16 capBps)
        internal
        pure
        returns (uint128)
    {
        if (notional == 0 || gapTicks == 0 || rateBps == 0) return 0;

        // 1 tick ≈ 1 bp, so gapTicks * rateBps is in hundredths of a bp: divide by 1e8.
        uint256 uncapped = FullMath.mulDiv(notional, uint256(gapTicks) * rateBps, 1e8);
        uint256 capped   = FullMath.mulDiv(notional, capBps, 1e4);

        uint256 surcharge = uncapped < capped ? uncapped : capped;

        // Cannot exceed the notional itself unless capBps is misconfigured above 100%;
        // the cast is checked rather than silently truncating a bad config.
        require(surcharge <= type(uint128).max, "surcharge overflow");
        return uint128(surcharge);
    }
}
