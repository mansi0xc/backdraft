// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2}        from "forge-std/Script.sol";
import {PoolManager}             from "v4-core/PoolManager.sol";
import {IPoolManager}            from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey}                 from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary}   from "v4-core/types/PoolId.sol";
import {Currency}                from "v4-core/types/Currency.sol";
import {IHooks}                  from "v4-core/interfaces/IHooks.sol";
import {Hooks}                   from "v4-core/libraries/Hooks.sol";

import {PoolSwapTest}            from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {TestERC20}               from "v4-core/test/TestERC20.sol";

import {HookMiner}               from "../lib/v4-periphery/test/shared/HookMiner.sol";

import {BackdraftHook}           from "../src/BackdraftHook.sol";
import {SplitV3Reference}        from "../src/references/SplitV3Reference.sol";
import {IReferencePrice}         from "../src/interfaces/IReferencePrice.sol";
import {MockV3Pool}              from "../test/mocks/MockV3Pool.sol";

/// @notice One-shot deploy for Anvil (chainid 31337) AND Sepolia (11155111): brings up
///         a full, working Backdraft pool with zero real capital required.
///
/// This exists because DeployHook.s.sol only deploys the hook + oracle and PRINTS the
/// four config steps rather than executing them (see review notes) — this script
/// executes them, so `--broadcast` finishing actually means the pool is usable.
///
/// Why mock reference pools instead of real v3 pools: a real Sepolia v3 ETH/USDC pool
/// (if one even exists with volume) tells you nothing — there's no real trading
/// activity informing its price, so the "most-traded, freshest" design assumption
/// this project is built on doesn't transfer to testnet. MockV3Pool is not a
/// compromise standing in for something better; for a demo, being ABLE to drive the
/// tick on command is strictly more useful than hoping a thin testnet pool drifts by
/// itself. No LP capital, no real tokens, no swap volume required to stand it up —
/// it is a bare contract that returns whatever tick/observation values you set.
///
/// Usage:
///   forge script script/DeployLocal.s.sol:DeployLocal --rpc-url <anvil_or_sepolia> --broadcast
///
/// Required env: PRIVATE_KEY
///
/// After this script finishes, the pool is swap-ready. To demo a price gap:
///   cast send <fastPool> "setTick(int24)" 70 --rpc-url ... --private-key ...
///   cast send <fastPool> "setCumulatives(int56,int56)" 0 126000 --rpc-url ... --private-key ...
///   (then swap through swapRouter — the surcharge + ledger attribution fire for real)
contract DeployLocal is Script {

    // Same permission bits as DeployHook.s.sol / BackdraftTestBase.
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG        |
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG    |
        Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
        Hooks.BEFORE_SWAP_FLAG             |
        Hooks.AFTER_SWAP_FLAG              |
        Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    uint24  constant FEE               = 3000;
    int24   constant TICK_SPACING      = 60;
    uint160 constant INIT_SQRT_PRICE   = 79228162514264337593543950336; // tick 0
    uint24  constant NO_FEE_OVERRIDE   = type(uint24).max;

    // Defaults taken from BackdraftTestBase / the empirical parameters documented in
    // CHANGES.md. divSlopeBps is 0 (neutral, 1.00x multiplier always) unless you pass
    // DEMO_DIV_SLOPE_BPS — set it nonzero if you want the appendix-10 graduated curve
    // to visibly do something during the demo instead of sitting at 1.00x.
    uint32 constant TWAP_WINDOW        = 1800;
    uint24 constant GUARD_MAX_DEV      = 50;
    uint24 constant FREEZE_MAX_DEV     = 250;
    uint24 constant GAP_THRESHOLD      = 65;
    uint16 constant CAPTURE_RATE_BPS   = 500;
    uint16 constant SURCHARGE_CAP_BPS  = 200;
    uint16 constant TRADER_SHARE_BPS   = 5000;
    uint32 constant MIN_AGE_BLOCKS     = 100;
    uint32 constant EXPIRY_BLOCKS      = 1000;
    uint32 constant SWEEP_GRACE_BLOCKS = 500;

    using PoolIdLibrary for PoolKey;

    function run() external {
        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        uint16  divSlopeBps   = uint16(vm.envOr("DEMO_DIV_SLOPE_BPS", uint256(0)));
        uint16  maxDivMultBps = divSlopeBps == 0 ? 10_000 : uint16(vm.envOr("DEMO_MAX_DIV_MULT_BPS", uint256(20_000)));

        console2.log("chainid :", block.chainid);
        console2.log("deployer:", deployer);

        vm.startBroadcast(pk);

        // 1. Core v4 infra + test routers (same routers your own test suite already
        //    exercises this hook against — safe to point a live testnet demo at them).
        PoolManager manager = new PoolManager(deployer);
        PoolSwapTest swapRouter = new PoolSwapTest(manager);
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(manager);
        console2.log("PoolManager :", address(manager));
        console2.log("SwapRouter  :", address(swapRouter));
        console2.log("LpRouter    :", address(lpRouter));

        // 2. Mock v3 reference pools -- no capital, no LPs, no swap volume needed.
        //    Both start at tick 0 to match the v4 pool's initial price.
        MockV3Pool fastPool = new MockV3Pool(0);
        MockV3Pool deepPool = new MockV3Pool(0);
        fastPool.setCumulatives(0, 0); // flat TWAP at tick 0
        deepPool.setCumulatives(0, 0);
        console2.log("FastPool (mock):", address(fastPool));
        console2.log("DeepPool (mock):", address(deepPool));

        // 3. Reference oracle + hook (identical pattern to DeployHook.s.sol)
        SplitV3Reference refOracle = new SplitV3Reference(deployer);
        bytes memory ctorArgs = abi.encode(address(manager), address(refOracle), deployer);
        (address expected, bytes32 salt) = HookMiner.find(
            0x4e59b44847b379578588920cA78FbF26c0B4956C, HOOK_FLAGS, type(BackdraftHook).creationCode, ctorArgs
        );
        BackdraftHook hook = new BackdraftHook{salt: salt}(
            IPoolManager(address(manager)), IReferencePrice(address(refOracle)), deployer
        );
        require(address(hook) == expected, "hook address mismatch");
        console2.log("SplitV3Reference:", address(refOracle));
        console2.log("BackdraftHook   :", address(hook));

        // 4. Tokens -- minted for free, no faucet, no bridging required
        TestERC20 tA = new TestERC20(type(uint128).max);
        TestERC20 tB = new TestERC20(type(uint128).max);
        (TestERC20 token0, TestERC20 token1) =
            address(tA) < address(tB) ? (tA, tB) : (tB, tA);
        console2.log("Token0:", address(token0));
        console2.log("Token1:", address(token1));

        PoolKey memory poolKey = PoolKey({
            currency0:   Currency.wrap(address(token0)),
            currency1:   Currency.wrap(address(token1)),
            fee:         FEE,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(address(hook))
        });
        PoolId poolId = poolKey.toId();

        // 5. Wire the four steps DeployHook.s.sol only prints -- executed here.
        hook.setRouterAllowed(address(swapRouter), true);
        hook.setRouterAllowed(address(lpRouter), true);

        refOracle.setConfig(poolId, SplitV3Reference.Config({
            fastPool:         address(fastPool),
            deepPool:         address(deepPool),
            twapWindow:       TWAP_WINDOW,
            guardMaxDevTicks: GUARD_MAX_DEV,
            freezeMaxDevTicks: FREEZE_MAX_DEV,
            invertTicks:      false
        }));

        hook.setPoolCfg(poolId, BackdraftHook.PoolCfg({
            guardMaxDevTicks:  GUARD_MAX_DEV,
            divSlopeBps:       divSlopeBps,
            maxDivMultBps:     maxDivMultBps,
            gapThresholdTicks: GAP_THRESHOLD,
            captureRateBps:    CAPTURE_RATE_BPS,
            surchargeCapBps:   SURCHARGE_CAP_BPS,
            traderShareBps:    TRADER_SHARE_BPS,
            baseFee:           FEE,
            narrowingFee:      NO_FEE_OVERRIDE,
            minAgeBlocks:      MIN_AGE_BLOCKS,
            expiryBlocks:      EXPIRY_BLOCKS,
            sweepGraceBlocks:  SWEEP_GRACE_BLOCKS
        }));

        // 6. Initialize the pool (afterInitialize validates the cfg set above)
        manager.initialize(poolKey, INIT_SQRT_PRICE);

        // 7. Seed liquidity so there's something to swap against
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower:      -600,
                tickUpper:      600,
                liquidityDelta: int256(uint256(1e18)),
                salt:           bytes32(0)
            }),
            abi.encode(deployer)
        );

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Ready. isReady:", refOracle.isReady(poolId) ? "true" : "false");
        console2.log("=== poolId (for cast calls):");
        console2.logBytes32(PoolId.unwrap(poolId));
        console2.log("=== To demo a price gap, drive fastPool's tick then swap:");
        console2.log("    cast send", address(fastPool), "\"setTick(int24)\" 70 --rpc-url $RPC_URL --private-key $PRIVATE_KEY");
    }
}
