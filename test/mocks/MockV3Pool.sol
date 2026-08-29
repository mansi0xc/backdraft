// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUniswapV3PoolMinimal} from "../../src/interfaces/IUniswapV3PoolMinimal.sol";

/// @notice Controllable stand-in for a Uniswap v3 pool.
///
///         Exists because the two defects it exercises are unreachable on a healthy
///         mainnet pool: `observe()` reverting for insufficient cardinality, and a
///         negative tickCumulative delta that does not divide evenly by the window.
///         A fork test against a live ETH/USDC pool can never produce either.
contract MockV3Pool is IUniswapV3PoolMinimal {
    int24   public tick;
    uint128 public poolLiquidity;
    uint16  public cardinality = 1000;

    /// Cumulative at `now` and at `window` seconds ago; the reference divides the delta.
    int56 public cumNow;
    int56 public cumAgo;

    /// When true, observe() reverts the way a v3 pool does with insufficient cardinality.
    bool public observeReverts;

    address public token0;
    address public token1;

    constructor(int24 _tick) {
        tick = _tick;
    }

    function setTick(int24 t) external { tick = t; }
    function setObserveReverts(bool v) external { observeReverts = v; }
    function setCumulatives(int56 ago, int56 nowCum) external {
        cumAgo = ago;
        cumNow = nowCum;
    }

    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
    {
        return (0, tick, 0, cardinality, cardinality, 0, true);
    }

    function observe(uint32[] calldata)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidity)
    {
        // v3 reverts with this error when the requested window predates the oldest
        // observation the pool retains.
        require(!observeReverts, "OLD");

        tickCumulatives = new int56[](2);
        tickCumulatives[0] = cumAgo;
        tickCumulatives[1] = cumNow;
        secondsPerLiquidity = new uint160[](2);
    }

    function liquidity() external view returns (uint128) { return poolLiquidity; }
    function increaseObservationCardinalityNext(uint16 n) external { cardinality = n; }
}
