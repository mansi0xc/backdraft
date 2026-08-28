// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {IReferencePrice} from "../../src/interfaces/IReferencePrice.sol";

/// @notice Controllable mock oracle for tests.
///         Call setRef() to move the reference tick and simulate market moves.
contract MockReferenceOracle is IReferencePrice {
    mapping(PoolId => int24) public refTicks;
    mapping(PoolId => bool) public frozen;

    function setRef(PoolId id, int24 tick) external {
        refTicks[id] = tick;
    }

    function setFrozen(PoolId id, bool isFrozen) external {
        frozen[id] = isFrozen;
    }

    function getRefTick(PoolId id) external view override returns (int24 refTick, bool ok) {
        if (frozen[id]) return (0, false);
        return (refTicks[id], true);
    }
}
