// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BackdraftTestBase} from "../BackdraftTestBase.sol";
import {BackdraftHook}     from "../../src/BackdraftHook.sol";
import {PoolSwapTest}      from "v4-core/test/PoolSwapTest.sol";
import {IPoolManager}      from "v4-core/interfaces/IPoolManager.sol";
import {TickMath}          from "v4-core/libraries/TickMath.sol";

// ============================================================
// Router allowlist / identity resolution tests.
//
// History: the hook used tx.origin as the identity for both swap contributions and LP
// positions. Uniswap's own v4-security-foundations skill (vendored in .agents/skills,
// pinned by hash in skills-lock.json) lists this as Absolute Prohibition #9:
//
//     "Never use tx.origin for authorization - It's a phishing vector; malicious
//      contracts can relay calls with the original user's tx.origin"
//
// The concrete failure is ERC-4337. For a UserOperation, tx.origin is the BUNDLER. A
// smart-account LP's position was therefore recorded against the bundler's address, and
// the bundler could call claimLp and be paid. Swap contributions had the same shape:
// a 4337 user's ledger credit accrued to whoever bundled their operation.
//
// The fix resolves identity from the ROUTER plus hookData, trusting hookData only from
// an allowlisted router — because an arbitrary router could otherwise name any address
// as the user and credit itself for someone else's swap, which is the same phishing
// vector merely relocated.
//
// WHY THESE TESTS EXIST AT ALL: after the migration, all 104 pre-existing tests still
// passed — and so did a mutation that reverted _resolveUser to `return tx.origin`. Every
// existing test pranks with vm.prank(actor, actor), so msg.sender, tx.origin and the
// hookData address all coincide and no test could tell the two implementations apart.
// These tests pull those identities apart deliberately.
// ============================================================
contract RouterAuthTest is BackdraftTestBase {

    address constant LP      = address(0x1001);
    address constant ACCOUNT = address(0xa0a0);   // ERC-4337 smart account (the real user)
    address constant BUNDLER = address(0xb0b0);   // relayer: becomes tx.origin
    address constant VICTIM  = address(0x1c71);
    address constant ROHAN   = address(0xaaaa);
    address constant VIK     = address(0xbbbb);

    int24 constant LO = -6000;
    int24 constant HI =  6000;

    PoolSwapTest untrustedRouter;

    function setUp() public override {
        super.setUp();
        _fund(LP); _fund(ACCOUNT); _fund(BUNDLER); _fund(ROHAN); _fund(VIK);

        // A router the hook has NOT allowlisted.
        untrustedRouter = new PoolSwapTest(manager);

        _addLiquidity(LP, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
    }

    function _fund(address who) internal {
        token0.transfer(who, 50_000_000e18);
        token1.transfer(who, 50_000_000e18);
    }

    function _contrib(uint256 idx, address who) internal view returns (uint128) {
        return hook.contribution(keccak256(abi.encode(poolId, idx, who)));
    }

    /// @dev Swap where msg.sender and tx.origin differ, as they do under ERC-4337:
    ///      the smart account calls the router, the bundler is tx.origin.
    function _relayedSwap(
        PoolSwapTest router,
        address account,
        address txOrigin,
        address namedUser,
        bool zeroForOne,
        int256 amountSpecified
    ) internal {
        vm.startPrank(account, txOrigin);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        router.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne:        zeroForOne,
                amountSpecified:   amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(namedUser)
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // ERC-4337: the bundler must get nothing
    // ------------------------------------------------------------------

    /// @notice The headline. A smart account swaps via an allowlisted router; the bundler
    ///         is tx.origin. Credit must reach the ACCOUNT, not the BUNDLER. Under the old
    ///         tx.origin implementation this credited the bundler.
    function test_BundlerDoesNotReceiveSwapAttribution() public {
        _relayedSwap(swapRouter, ACCOUNT, BUNDLER, ACCOUNT, false, -500_000e18);

        uint256 idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "precondition: gap must open");

        assertGt(_contrib(idx, ACCOUNT), 0, "the account must receive the credit");
        assertEq(_contrib(idx, BUNDLER), 0, "the bundler must receive nothing");
    }

    /// @notice And the account can actually collect it, while the bundler cannot.
    function test_BundlerCannotClaimTheAccountsTraderPot() public {
        _relayedSwap(swapRouter, ACCOUNT, BUNDLER, ACCOUNT, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        _swap(VIK, true, -2_000_000e18);
        if (!hook.gapAt(poolId, idx).settled) hook.settle(poolId, idx);

        vm.prank(BUNDLER, BUNDLER);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "nothing"));
        hook.claimTrader(poolId, idx);

        uint256 before = token0.balanceOf(ACCOUNT) + token1.balanceOf(ACCOUNT);
        vm.prank(ACCOUNT, ACCOUNT);
        hook.claimTrader(poolId, idx);
        assertGt(token0.balanceOf(ACCOUNT) + token1.balanceOf(ACCOUNT), before,
            "the account must be able to collect its own credit");
    }

    /// @notice Same for liquidity: the position belongs to the account, not the bundler.
    ///         Under the old implementation the bundler could have claimed this payout.
    function test_BundlerDoesNotOwnTheAccountsLpPosition() public {
        // ACCOUNT adds liquidity through an allowlisted router, BUNDLER as tx.origin.
        vm.startPrank(ACCOUNT, BUNDLER);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: LO, tickUpper: HI,
                liquidityDelta: int256(uint256(5_000_000e18)), salt: bytes32(0)
            }),
            abi.encode(ACCOUNT)
        );
        vm.stopPrank();

        (uint128 acctLiq,,,) = hook.positions(
            hook.positionKeyFor(poolId, ACCOUNT, LO, HI, bytes32(0))
        );
        (uint128 bundlerLiq,,,) = hook.positions(
            hook.positionKeyFor(poolId, BUNDLER, LO, HI, bytes32(0))
        );

        assertGt(acctLiq, 0, "position must be recorded against the account");
        assertEq(bundlerLiq, 0, "no position may be recorded against the bundler");
    }

    // ------------------------------------------------------------------
    // An untrusted router must not be able to name anyone
    // ------------------------------------------------------------------

    /// @notice A router the hook does not allowlist can claim anything it likes in
    ///         hookData. The hook must ignore it, or the phishing vector is simply
    ///         relocated from tx.origin to hookData.
    function test_UntrustedRouterCannotNameAnotherUser() public {
        _relayedSwap(untrustedRouter, ROHAN, ROHAN, VICTIM, false, -500_000e18);

        uint256 idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "precondition: gap must open");

        assertEq(_contrib(idx, VICTIM), 0, "an untrusted router must not name a user");
        assertGt(_contrib(idx, address(untrustedRouter)), 0,
            "credit falls back to the router itself");
    }

    /// @notice Falling back must never become a way to avoid paying. The surcharge is
    ///         charged identically through an unrecognised router — only the rebate is
    ///         lost. Otherwise "route through an unknown contract" would be bypass #2.
    function test_UntrustedRouterStillPaysTheSurcharge() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "precondition: gap must open");

        uint128 before = hook.gapAt(poolId, idx).escrowed;
        _relayedSwap(untrustedRouter, VIK, VIK, VIK, true, -400_000e18);

        assertGt(hook.gapAt(poolId, idx).escrowed, before,
            "surcharge must not depend on the router allowlist");
    }

    /// @notice A hook must not brick swaps for anyone using an unrecognised router —
    ///         same freeze-not-revert principle the reference guard follows.
    function test_UntrustedRouterSwapStillSucceeds() public {
        uint256 before = token1.balanceOf(ROHAN);
        _relayedSwap(untrustedRouter, ROHAN, ROHAN, ROHAN, true, -100_000e18);
        assertGt(token1.balanceOf(ROHAN), before, "swap must still execute");
    }

    // ------------------------------------------------------------------
    // Allowlist mechanics
    // ------------------------------------------------------------------

    /// @notice Allowlisting is what flips the behaviour, and revoking flips it back.
    function test_AllowlistTogglesAttribution() public {
        hook.setRouterAllowed(address(untrustedRouter), true);
        _relayedSwap(untrustedRouter, ROHAN, ROHAN, ACCOUNT, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        assertGt(_contrib(idx, ACCOUNT), 0, "allowlisted router's hookData is honoured");

        hook.setRouterAllowed(address(untrustedRouter), false);
        _relayedSwap(untrustedRouter, ROHAN, ROHAN, VICTIM, false, -200_000e18);
        assertEq(_contrib(idx, VICTIM), 0, "revoked router's hookData is ignored again");
    }

    function test_OnlyOwnerCanAllowlist() public {
        vm.prank(VIK, VIK);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "not owner"));
        hook.setRouterAllowed(address(untrustedRouter), true);
    }

    /// @notice Malformed hookData from an allowlisted router falls back to the router
    ///         rather than reverting or decoding garbage.
    function test_MalformedHookDataFallsBackToRouter() public {
        vm.startPrank(ROHAN, ROHAN);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: -500_000e18,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hex"deadbeef"                          // not 32 bytes
        );
        vm.stopPrank();

        uint256 idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "precondition: gap must open");
        assertGt(_contrib(idx, address(swapRouter)), 0, "falls back to the router");
        assertEq(_contrib(idx, ROHAN), 0, "must not silently use msg.sender");
    }

    /// @notice A zero address in hookData is not a valid identity.
    function test_ZeroAddressHookDataFallsBackToRouter() public {
        _relayedSwap(swapRouter, ROHAN, ROHAN, address(0), false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        assertEq(_contrib(idx, address(0)), 0, "zero address must never hold credit");
        assertGt(_contrib(idx, address(swapRouter)), 0, "falls back to the router");
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    /// @notice Whoever the relayer is, credit follows the named account.
    function testFuzz_AttributionIndependentOfTxOrigin(address relayer) public {
        vm.assume(relayer != address(0) && relayer != ACCOUNT);
        vm.assume(relayer.code.length == 0);

        _relayedSwap(swapRouter, ACCOUNT, relayer, ACCOUNT, false, -500_000e18);

        uint256 idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "precondition: gap must open");
        assertGt(_contrib(idx, ACCOUNT), 0, "account must hold the credit");
        assertEq(_contrib(idx, relayer), 0, "relayer must never hold credit");
    }

    /// @notice An untrusted router cannot mint credit for an arbitrary address.
    function testFuzz_UntrustedRouterCannotNameAnyAddress(address named) public {
        vm.assume(named != address(untrustedRouter) && named != address(0));

        _relayedSwap(untrustedRouter, ROHAN, ROHAN, named, false, -500_000e18);

        uint256 idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "precondition: gap must open");
        assertEq(_contrib(idx, named), 0, "untrusted router named an address successfully");
    }
}
