// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library SurchargeMath {
    /// @param notional   Absolute swap amount (|amountSpecified|)
    /// @param gapTicks   |poolTick - refTick| before the swap
    /// @param rateBps    captureRateBps — basis points per tick of gap
    /// @param capBps     Hard ceiling on total surcharge rate (basis points)
    /// @return surcharge Token amount to collect from the swapper
    function compute(uint256 notional, uint24 gapTicks, uint16 rateBps, uint16 capBps)
        internal
        pure
        returns (uint128)
    {
        // 1 tick ≈ 1 bp; rate * gap gives total bps
        uint256 bps = (uint256(gapTicks) * rateBps) / 10_000;
        if (bps > capBps) bps = capBps;
        return uint128((notional * bps) / 10_000);
    }
}
