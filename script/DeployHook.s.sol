// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2}   from "forge-std/Script.sol";
import {IPoolManager}       from "v4-core/interfaces/IPoolManager.sol";
import {Hooks}              from "v4-core/libraries/Hooks.sol";
import {HookMiner}          from "../lib/v4-periphery/test/shared/HookMiner.sol";
import {BackdraftHook}      from "../src/BackdraftHook.sol";
import {SplitV3Reference}   from "../src/references/SplitV3Reference.sol";
import {IReferencePrice}    from "../src/interfaces/IReferencePrice.sol";

/// @notice Deploys SplitV3Reference and BackdraftHook at a CREATE2 address whose low
///         bits encode the hook's permission set.
///
/// Usage:
///   forge script script/DeployHook.s.sol:DeployHook --rpc-url $RPC_URL --broadcast
///
/// Required env (see .env.example): PRIVATE_KEY
///
/// After deployment THREE things must happen before the hook does anything useful.
/// They are printed at the end of the run because every one of them fails silently:
///   1. refOracle.setConfig(...) and hook.setPoolCfg(...)
///   2. hook.setRouterAllowed(router, true) -- without it NO end user is ever credited
///   3. refOracle.isReady(poolId) -- false means the deep pool's observation cardinality
///      cannot serve the TWAP window, so the hook will only ever freeze
contract DeployHook is Script {

    /// @dev CREATE2 deployer proxy; same address on every chain Foundry supports.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    struct NetworkConfig {
        address poolManager;
        address fastPool;   // v3 0.01% -- refOracle price (most-traded, so freshest)
        address deepPool;   // v3 0.05% -- manipulation guard (deepest, hardest to push)
        string  name;
    }

    function _config() internal view returns (NetworkConfig memory) {
        if (block.chainid == 1) {
            return NetworkConfig({
                poolManager: 0x000000000004444c5dc75cB358380D2e3dE08A90,
                fastPool:    0xE0554a476A092703abdB3Ef35c80e0D76d32939F, // ETH/USDC 0.01%
                deepPool:    0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640, // ETH/USDC 0.05%
                name:        "mainnet"
            });
        }
        if (block.chainid == 11155111) {
            return NetworkConfig({
                poolManager: 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543,
                fastPool:    address(0),   // set before configuring a pool on Sepolia
                deepPool:    address(0),
                name:        "sepolia"
            });
        }
        // Local anvil / unknown chain: read from env so the script runs end to end.
        return NetworkConfig({
            poolManager: vm.envOr("POOL_MANAGER", address(0)),
            fastPool:    vm.envOr("FAST_POOL",    address(0)),
            deepPool:    vm.envOr("DEEP_POOL",    address(0)),
            name:        "local"
        });
    }

    function run() external returns (BackdraftHook hook, SplitV3Reference refOracle) {
        NetworkConfig memory net = _config();
        require(net.poolManager != address(0), "POOL_MANAGER unset for this chain");

        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("network :", net.name);
        console2.log("chainid :", block.chainid);
        console2.log("deployer:", deployer);

        vm.startBroadcast(pk);

        refOracle = new SplitV3Reference(deployer);
        console2.log("SplitV3Reference:", address(refOracle));

        // The hook address must encode exactly these bits or the PoolManager will not
        // call the callbacks. BackdraftHook's constructor asserts this via
        // Hooks.validateHookPermissions, so a bad salt fails HERE rather than silently
        // in production.
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG        |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG    |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG             |
            Hooks.AFTER_SWAP_FLAG              |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory ctorArgs = abi.encode(net.poolManager, address(refOracle), deployer);

        (address expected, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, flags, type(BackdraftHook).creationCode, ctorArgs
        );
        console2.log("mined hook address:", expected);

        hook = new BackdraftHook{salt: salt}(
            IPoolManager(net.poolManager),
            IReferencePrice(address(refOracle)),
            deployer
        );
        require(address(hook) == expected, "hook address mismatch: salt/args drift");
        console2.log("BackdraftHook:", address(hook));

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== REQUIRED before this hook does anything ===");
        console2.log("1. refOracle.setConfig(poolId, {fastPool, deepPool, 1800, 50, 250, invertTicks})");
        console2.log("   fields: twapWindow, guardMaxDevTicks, freezeMaxDevTicks, invertTicks");
        console2.log("   guardMaxDevTicks (50) is where the divergence surcharge curve starts,");
        console2.log("   NOT a freeze point. freezeMaxDevTicks (250) is the absurdity backstop;");
        console2.log("   set it to 0 to disable freezing on divergence entirely (appendix 10).");
        console2.log("   fastPool:", net.fastPool);
        console2.log("   deepPool:", net.deepPool);
        console2.log("   invertTicks: true if the v3 pair's token order differs from the v4 pool's");
        console2.log("2. hook.setPoolCfg(poolId, {...}) BEFORE initialize. afterInitialize does");
        console2.log("   NOT revert without it: a dynamic-fee pool is seeded with baseFee=0 and");
        console2.log("   trades fee-free until setPoolCfg is called (which now re-pushes the fee).");
        console2.log("   divSlopeBps / maxDivMultBps drive the divergence curve. Leaving");
        console2.log("   divSlopeBps at 0 keeps the multiplier at 1.00x, which restores the");
        console2.log("   pre-appendix-10 behaviour of not pricing reference manipulation.");
        console2.log("3. hook.setRouterAllowed(universalRouter, true) and positionManager");
        console2.log("   WITHOUT THIS no end user is ever credited: attribution falls back");
        console2.log("   to router addresses. Swaps still work and are still surcharged,");
        console2.log("   so this failure is silent.");
        console2.log("4. require(refOracle.isReady(poolId)) -- false means the deep pool needs");
        console2.log("   increaseObservationCardinalityNext(). observe() failure is now the");
        console2.log("   MAIN remaining freeze condition, since divergence no longer freezes.");
    }
}
