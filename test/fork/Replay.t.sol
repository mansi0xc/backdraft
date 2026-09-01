// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SplitV3Reference} from "../../src/references/SplitV3Reference.sol";
import {IUniswapV3PoolMinimal} from "../../src/interfaces/IUniswapV3PoolMinimal.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Day 1 — Roshan fork spike: validate the reference reader against mainnet pools.
/// Run with: forge test --match-contract ReplayForkTest --fork-url $MAINNET_RPC_URL -vvvv
contract ReplayForkTest is Test {
    // From refbench/discover.py
    address constant FAST_POOL = 0xE0554a476A092703abdB3Ef35c80e0D76d32939F; // v3 0.01% ETH/USDC
    address constant DEEP_POOL = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // v3 0.05% ETH/USDC

    SplitV3Reference ref;

    function setUp() public {
        ref = new SplitV3Reference(address(this));
    }

    modifier onlyFork() {
        vm.skip(block.chainid == 31337);
        _;
    }

    /// @notice Sanity: read spot ticks from both pools and the TWAP, print guard decision.
    function test_ReferenceReaderOnMainnet() public onlyFork {

        (, int24 fastTick,,,,,)  = IUniswapV3PoolMinimal(FAST_POOL).slot0();
        (, int24 deepTick,,,,,)  = IUniswapV3PoolMinimal(DEEP_POOL).slot0();

        // TWAP — 1800s window
        uint32[] memory ago = new uint32[](2);
        ago[0] = 1800; ago[1] = 0;
        (int56[] memory cum,) = IUniswapV3PoolMinimal(DEEP_POOL).observe(ago);
        int24 deepTwap = int24((cum[1] - cum[0]) / int56(uint56(1800)));

        emit log_named_int("fast tick",     fastTick);
        emit log_named_int("deep tick",     deepTick);
        emit log_named_int("deep TWAP",     deepTwap);
        emit log_named_int("fast-deep diff", fastTick - deepTick);
        emit log_named_int("deep spot-TWAP", deepTick - deepTwap);
    }

    /// @notice Measure gas for reference() call.
    function test_ReferenceGas() public onlyFork {

        // Build a dummy PoolId for the config
        PoolId id = PoolId.wrap(bytes32(uint256(1)));
        ref.setConfig(id, SplitV3Reference.Config({
            fastPool:         FAST_POOL,
            deepPool:         DEEP_POOL,
            twapWindow:        1800,
            guardMaxDevTicks:  50,
            freezeMaxDevTicks: 250,
            invertTicks:       false
        }));

        uint256 gasBefore = gasleft();
        (int24 tick, bool ok, uint24 divTicks) = ref.getRefTick(id);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("reference() gas", gasUsed);
        emit log_named_int("refTick", tick);
        emit log_named_string("ok", ok ? "true" : "false");
        emit log_named_uint("divTicks", divTicks);
    }
}
