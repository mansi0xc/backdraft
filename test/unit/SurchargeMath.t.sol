// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SurchargeMath} from "../../src/libraries/SurchargeMath.sol";

contract SurchargeMathTest is Test {
    // captureRateBps = 500 (5%), capBps = 200 (2%)
    uint16 constant RATE = 500;
    uint16 constant CAP  = 200;

    function test_BasicSurcharge() public pure {
        // notional = 10_000, gapTicks = 100, rate = 500
        // bps = 100 * 500 / 10000 = 5 bps, surcharge = 10000 * 5 / 10000 = 5
        uint128 s = SurchargeMath.compute(10_000, 100, RATE, CAP);
        assertEq(s, 5);
    }

    function test_SurchargeRespectsCap() public pure {
        // gapTicks = 10_000 => bps = 10000*500/10000 = 500 => capped at CAP=200
        // surcharge = 10_000 * 200 / 10_000 = 200
        uint128 s = SurchargeMath.compute(10_000, 10_000, RATE, CAP);
        assertEq(s, 200);
    }

    function test_ZeroNotional() public pure {
        assertEq(SurchargeMath.compute(0, 100, RATE, CAP), 0);
    }

    function test_ZeroGap() public pure {
        assertEq(SurchargeMath.compute(10_000, 0, RATE, CAP), 0);
    }

    function test_ZeroRate() public pure {
        assertEq(SurchargeMath.compute(10_000, 100, 0, CAP), 0);
    }
}
