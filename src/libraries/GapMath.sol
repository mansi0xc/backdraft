// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library GapMath {
    function abs(int24 x) internal pure returns (uint24) {
        return x < 0 ? uint24(-x) : uint24(x);
    }

    /// @dev True when the swap direction moves the pool tick toward refTick.
    function isNarrowing(int24 gapBefore, bool zeroForOne) internal pure returns (bool) {
        // zeroForOne => price decreases => tick decreases
        // narrowing when gap is positive and tick is falling, or gap is negative and tick is rising
        return (gapBefore > 0 && zeroForOne) || (gapBefore < 0 && !zeroForOne);
    }
}
