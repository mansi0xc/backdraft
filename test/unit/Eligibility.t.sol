// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {EligibilityLib} from "../../src/libraries/EligibilityLib.sol";

contract EligibilityTest is Test {
    uint32 constant MIN_AGE = 100;

    function test_EligiblePosition() public pure {
        // addBlock=0, gapOpenBlock=200, minAge=100 → 0+100 ≤ 200 ✓
        assertTrue(EligibilityLib.isEligible(0, 200, MIN_AGE));
    }

    function test_TooNewPosition() public pure {
        // addBlock=150, gapOpenBlock=200, minAge=100 → 150+100 > 200 ✗
        assertFalse(EligibilityLib.isEligible(150, 200, MIN_AGE));
    }

    function test_ExactlyAtBoundaryEligible() public pure {
        // addBlock=100, gapOpenBlock=200, minAge=100 → 100+100 ≤ 200 ✓
        assertTrue(EligibilityLib.isEligible(100, 200, MIN_AGE));
    }

    function test_InRangeAtOpen() public pure {
        assertTrue(EligibilityLib.isInRange(-60, 60, 0));
        assertTrue(EligibilityLib.isInRange(-60, 60, 59));
        assertTrue(EligibilityLib.isInRange(-60, 60, -60));
    }

    function test_OutOfRangeAtOpen() public pure {
        assertFalse(EligibilityLib.isInRange(-60, 60, 60));  // tickAtOpen == tickUpper is excluded
        assertFalse(EligibilityLib.isInRange(-60, 60, -61));
        assertFalse(EligibilityLib.isInRange(-60, 60, 100));
    }
}
