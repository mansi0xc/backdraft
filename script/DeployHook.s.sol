// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BackdraftHook} from "../src/BackdraftHook.sol";
import {SplitV3Reference} from "../src/references/SplitV3Reference.sol";

/// @notice Deploy script — fills in the HookMiner salt before deployment.
///         Hook address must encode the correct permission bits per Hooks.sol.
///         Use HookMiner.find(...) to mine the CREATE2 salt.
///         See plan.md §4 — wrong flags → HookAddressNotValid on first pool interaction.
contract DeployHook is Script {
    // Mainnet PoolManager — update per network
    address constant POOL_MANAGER = address(0); // TODO: fill in

    function run() external {
        vm.startBroadcast();

        SplitV3Reference refOracle = new SplitV3Reference(msg.sender);
        console2.log("SplitV3Reference:", address(refOracle));

        // TODO: mine CREATE2 salt for correct hook address bit pattern
        // BackdraftHook hook = new BackdraftHook(IPoolManager(POOL_MANAGER), refOracle);
        // console2.log("BackdraftHook:", address(hook));

        vm.stopBroadcast();
    }
}
