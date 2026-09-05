// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {IReferencePrice} from "../../src/interfaces/IReferencePrice.sol";

/// @notice Controllable mock oracle for tests.
///         Call setRef() to move the reference tick and simulate market moves.
contract MockReferenceOracle is IReferencePrice {
    mapping(PoolId => int24) public refTicks;
    mapping(PoolId => bool) public frozen;
    mapping(PoolId => uint24) public divergence;

    function setRef(PoolId id, int24 tick) external {
        refTicks[id] = tick;
    }

    function setFrozen(PoolId id, bool isFrozen) external {
        frozen[id] = isFrozen;
    }

    /// @notice Simulate reference-source disagreement without freezing.
    function setDivergence(PoolId id, uint24 divTicks) external {
        divergence[id] = divTicks;
    }

    function getRefTick(PoolId id)
        public
        view
        override
        returns (int24 refTick, bool ok, uint24 divTicks)
    {
        if (frozen[id]) return (0, false, divergence[id]);
        return (refTicks[id], true, divergence[id]);
    }

    /// @dev The mock keeps no per-read state, so committing is a no-op. Hook tests
    ///      exercise gap mechanics, not reference behaviour; truncation is covered
    ///      against the real oracle in test/reference/ReferenceTruncation.t.sol.
    function updateRefTick(PoolId id)
        external
        view
        override
        returns (int24, bool, uint24)
    {
        return getRefTick(id);
    }
}
