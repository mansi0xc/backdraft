// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IReferencePrice} from "../interfaces/IReferencePrice.sol";

/// @notice BROKEN BASELINE — included only for measurement comparison.
/// @dev Uses a damped EMA of the pool's own tick history.
///      Fatal flaw: in the exogenous case the market moves, the pool goes stale,
///      and this EMA — which IS the pool's own history — reports zero gap.
///      See the README (Reference price) for the explanation and the measured error.
///      DO NOT use in production. Exists so the README can show the 16.6× accuracy
///      difference vs SplitV3Reference.
contract OwnPoolEmaReference is IReferencePrice {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;

    struct EmaState {
        int24  ema;
        uint48 lastBlock;
        uint8  alpha; // decay numerator out of 100; higher = faster decay
    }

    mapping(PoolId => EmaState) public state;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function update(PoolId id, PoolId /* unused */) external {
        EmaState storage s = state[id];
        (, int24 tick,,) = poolManager.getSlot0(id);
        if (s.lastBlock == 0) {
            s.ema = tick;
        } else {
            // damped EMA: ema = alpha*tick + (100-alpha)*ema / 100
            int32 next = (int32(uint32(s.alpha)) * tick + int32(uint32(100 - s.alpha)) * s.ema) / 100;
            s.ema = int24(next);
        }
        s.lastBlock = uint48(block.number);
    }

    /// @dev Single-source by construction: there is no second source to disagree with,
    ///      so divTicks is always 0 and the caller's divergence curve stays at 1.00x.
    ///      This reference is retained only as the measured-and-rejected baseline
    ///      (appendix §5); a pool cannot detect its own staleness from its own history.
    function getRefTick(PoolId id)
        external
        view
        override
        returns (int24 refTick, bool ok, uint24 divTicks)
    {
        EmaState storage s = state[id];
        if (s.lastBlock == 0) return (0, false, 0);
        return (s.ema, true, 0);
    }
}
