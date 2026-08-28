// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GapMath} from "../../src/libraries/GapMath.sol";

contract GapMathTest is Test {
    function test_AbsPositive() public pure {
        assertEq(GapMath.abs(100), 100);
    }

    function test_AbsNegative() public pure {
        assertEq(GapMath.abs(-100), 100);
    }

    function test_AbsZero() public pure {
        assertEq(GapMath.abs(0), 0);
    }

    function test_IsNarrowingPositiveGapZeroForOne() public pure {
        // gap > 0 (pool above ref), zeroForOne drives price down → narrowing
        assertTrue(GapMath.isNarrowing(100, true));
    }

    function test_IsNarrowingNegativeGapOneForZero() public pure {
        // gap < 0 (pool below ref), oneForZero drives price up → narrowing
        assertTrue(GapMath.isNarrowing(-100, false));
    }

    function test_NotNarrowingPositiveGapOneForZero() public pure {
        assertFalse(GapMath.isNarrowing(100, false));
    }

    function test_NotNarrowingNegativeGapZeroForOne() public pure {
        assertFalse(GapMath.isNarrowing(-100, true));
    }

    function test_NotNarrowingZeroGap() public pure {
        // zero gap: no direction is narrowing
        assertFalse(GapMath.isNarrowing(0, true));
        assertFalse(GapMath.isNarrowing(0, false));
    }
}
