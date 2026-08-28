// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library EligibilityLib {
    /// @dev Check if a position was old enough at gap-open to be eligible for the LP pot.
    /// @param addBlock      Block at which position was last increased
    /// @param gapOpenBlock  Block at which the gap opened
    /// @param minAgeBlocks  Required age in blocks
    function isEligible(uint48 addBlock, uint48 gapOpenBlock, uint32 minAgeBlocks)
        internal
        pure
        returns (bool)
    {
        return uint256(addBlock) + minAgeBlocks <= uint256(gapOpenBlock);
    }

    /// @dev Check if a position tick range covers the pool tick at gap-open.
    function isInRange(int24 tickLower, int24 tickUpper, int24 tickAtOpen)
        internal
        pure
        returns (bool)
    {
        return tickLower <= tickAtOpen && tickAtOpen < tickUpper;
    }
}
