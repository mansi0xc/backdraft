// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {IReferencePrice} from "../interfaces/IReferencePrice.sol";
import {IUniswapV3PoolMinimal} from "../interfaces/IUniswapV3PoolMinimal.sol";

/// @notice External v3 reference price with two-tier guard.
///
/// Reference:  v3 0.01% spot tick   — freshest, most-frequently-corrected
/// Guard:      v3 0.05% spot vs TWAP — deepest, hardest to push
///
/// Freeze conditions (returns ok=false — caller must treat as no-op):
///   1. |deepSpot − deepTwap| > guardMaxDevTicks  → deep source being manipulated
///   2. |fastSpot − deepSpot| > guardMaxDevTicks  → fast source being manipulated
///
/// See idea.md §4 for the measurement rationale and §4.4 for design.
contract SplitV3Reference is IReferencePrice {
    // -------------------------------------------------------------------------
    // Config (immutable per deployment — pool pairs are fixed)
    // -------------------------------------------------------------------------

    struct Config {
        address fastPool;         // v3 0.01% — reference tick source
        address deepPool;         // v3 0.05% — manipulation guard
        uint32  twapWindow;       // guard TWAP window in seconds (1800)
        uint24  guardMaxDevTicks; // freeze threshold (50 ticks → ~6.6% freeze rate calm)
        bool    invertTicks;      // true when v3 token0/token1 order differs from v4
    }

    mapping(PoolId => Config) public configs;
    address public immutable owner;

    constructor(address _owner) {
        owner = _owner;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function setConfig(PoolId id, Config calldata cfg) external onlyOwner {
        require(cfg.fastPool != address(0) && cfg.deepPool != address(0), "zero addr");
        require(cfg.twapWindow >= 60, "twap too short");
        configs[id] = cfg;
    }

    // -------------------------------------------------------------------------
    // IReferencePrice
    // -------------------------------------------------------------------------

    function getRefTick(PoolId id) external view override returns (int24 refTick, bool ok) {
        Config storage c = configs[id];
        if (c.fastPool == address(0)) return (0, false);

        int24 fast     = _spotTick(c.fastPool);
        int24 deep     = _spotTick(c.deepPool);
        int24 deepTwap = _twapTick(c.deepPool, c.twapWindow);

        // Guard 1: deep source itself is being manipulated
        if (_abs(deep - deepTwap) > c.guardMaxDevTicks) return (0, false);
        // Guard 2: fast source diverges from agreed-upon deep price
        if (_abs(fast - deep)     > c.guardMaxDevTicks) return (0, false);

        refTick = c.invertTicks ? -fast : fast;
        ok = true;
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    function _spotTick(address pool) internal view returns (int24 t) {
        (, t,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
    }

    function _twapTick(address pool, uint32 window) internal view returns (int24) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        ago[1] = 0;
        (int56[] memory cum,) = IUniswapV3PoolMinimal(pool).observe(ago);
        return int24((cum[1] - cum[0]) / int56(uint56(window)));
    }

    function _abs(int24 x) internal pure returns (uint24) {
        return x < 0 ? uint24(-x) : uint24(x);
    }
}
