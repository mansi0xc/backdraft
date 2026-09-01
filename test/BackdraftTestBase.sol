// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager}      from "v4-core/PoolManager.sol";
import {IPoolManager}     from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey}          from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks}           from "v4-core/interfaces/IHooks.sol";
import {Hooks}            from "v4-core/libraries/Hooks.sol";
import {TickMath}         from "v4-core/libraries/TickMath.sol";
import {StateLibrary}     from "v4-core/libraries/StateLibrary.sol";

import {PoolSwapTest}           from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {TestERC20}              from "v4-core/test/TestERC20.sol";

import {HookMiner} from "../lib/v4-periphery/test/shared/HookMiner.sol";

import {BackdraftHook}       from "../src/BackdraftHook.sol";
import {MockReferenceOracle} from "./mocks/MockReferenceOracle.sol";

abstract contract BackdraftTestBase is Test {
    using PoolIdLibrary  for PoolKey;
    using StateLibrary   for IPoolManager;
    using CurrencyLibrary for Currency;

    // -------------------------------------------------------------------------
    // Core v4 infrastructure
    // -------------------------------------------------------------------------
    PoolManager             public manager;
    PoolSwapTest            public swapRouter;
    PoolModifyLiquidityTest public lpRouter;

    // -------------------------------------------------------------------------
    // Backdraft
    // -------------------------------------------------------------------------
    MockReferenceOracle public oracle;
    BackdraftHook       public hook;

    // -------------------------------------------------------------------------
    // Tokens & pool
    // -------------------------------------------------------------------------
    TestERC20 public token0;
    TestERC20 public token1;
    PoolKey   public poolKey;
    PoolId    public poolId;

    // Pool parameters
    uint24 constant FEE          = 3000;
    int24  constant TICK_SPACING = 60;
    // Initial price: 1:1 (tick 0)
    uint160 constant INIT_SQRT_PRICE = 79228162514264337593543950336; // sqrtPriceX96 for tick 0

    // Hook config defaults — kept public so individual tests can override before setUp
    uint16 public captureRateBps   = 500;
    uint16 public surchargeCapBps  = 200;
    uint16 public traderShareBps   = 5000; // 50% alpha
    uint32 public minAgeBlocks     = 100;
    uint32 public sweepGraceBlocks = 500;
    uint32 public expiryBlocks     = 1000;
    uint24 public gapThresholdTicks = 65;

    // Divergence curve (appendix §10 — replaces the boolean freeze on source
    // disagreement). Default is neutral at 1.00x so every pre-existing test keeps its
    // measured expectations; GraduatedFee.t.sol overrides these before setUp().
    uint16 public divSlopeBps      = 0;
    uint16 public maxDivMultBps    = 10_000;

    // -------------------------------------------------------------------------
    // setUp
    // -------------------------------------------------------------------------
    function setUp() public virtual {
        // 1. Deploy core
        manager    = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter   = new PoolModifyLiquidityTest(manager);

        // 2. Deploy oracle mock
        oracle = new MockReferenceOracle();

        // 3. Mine a CREATE2 salt so the hook address encodes the right permission bits
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG      |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG  |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG           |
            Hooks.AFTER_SWAP_FLAG            |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(BackdraftHook).creationCode,
            abi.encode(address(manager), address(oracle), address(this))
        );

        hook = new BackdraftHook{salt: salt}(
            IPoolManager(address(manager)),
            oracle,
            address(this) // owner
        );
        require(address(hook) == hookAddr, "hook addr mismatch");

        // Trust the v4-core test routers to name the end user in hookData. In
        // production this is the deliberate trust decision described on
        // BackdraftHook.setRouterAllowed: an allowlisted router can name any address.
        hook.setRouterAllowed(address(swapRouter), true);
        hook.setRouterAllowed(address(lpRouter),   true);

        // 4. Deploy tokens (sorted so currency0 < currency1)
        TestERC20 tA = new TestERC20(type(uint128).max);
        TestERC20 tB = new TestERC20(type(uint128).max);
        if (address(tA) < address(tB)) {
            token0 = tA; token1 = tB;
        } else {
            token0 = tB; token1 = tA;
        }

        // 5. Approve routers
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(lpRouter),   type(uint256).max);
        token1.approve(address(lpRouter),   type(uint256).max);

        // 6. Build pool key and configure hook
        poolKey = PoolKey({
            currency0:   Currency.wrap(address(token0)),
            currency1:   Currency.wrap(address(token1)),
            fee:         FEE,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(address(hook))
        });
        poolId = poolKey.toId();

        // 7. Register pool config with hook (before initialize so afterInitialize can validate)
        hook.setPoolCfg(poolId, BackdraftHook.PoolCfg({
            fastPool:          address(0), // not used — oracle is mocked
            deepPool:          address(0),
            twapWindow:        1800,
            guardMaxDevTicks:  50,
            divSlopeBps:       divSlopeBps,
            maxDivMultBps:     maxDivMultBps,
            gapThresholdTicks: gapThresholdTicks,
            captureRateBps:    captureRateBps,
            surchargeCapBps:   surchargeCapBps,
            traderShareBps:    traderShareBps,
            minAgeBlocks:      minAgeBlocks,
            expiryBlocks:      expiryBlocks,
            sweepGraceBlocks:  sweepGraceBlocks,
            invertTicks:       false
        }));

        // 8. Initialize the pool (triggers afterInitialize on the hook)
        manager.initialize(poolKey, INIT_SQRT_PRICE);

        // 9. Seed the oracle at tick 0 (pool starts at tick 0, so no gap initially)
        oracle.setRef(poolId, 0);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev Add liquidity centred around tick 0
    function _addLiquidity(address lp, int24 tickLower, int24 tickUpper, uint128 liquidity) internal {
        vm.startPrank(lp, lp);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);

        lpRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower:      tickLower,
                tickUpper:      tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt:           bytes32(0)
            }),
            abi.encode(lp)          // hookData: allowlisted router names the LP
        );
        vm.stopPrank();
    }

    /// @dev Execute a swap. amountSpecified < 0 = exact-input.
    function _swap(address swapper, bool zeroForOne, int256 amountSpecified) internal returns (int256, int256) {
        vm.startPrank(swapper, swapper);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims:       false,
            settleUsingBurn:  false
        });

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne:        zeroForOne,
            amountSpecified:   amountSpecified,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(poolKey, params, settings, abi.encode(swapper));
        vm.stopPrank();

        return (0, 0); // delta not needed by most callers
    }

    /// @dev Current pool tick
    function _poolTick() internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(manager, poolId);
    }

    /// @dev Hook's ERC-6909 balance for a given currency
    function _hookBalance(Currency currency) internal view returns (uint256) {
        return manager.balanceOf(address(hook), currency.toId());
    }
}
