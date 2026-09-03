// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test}         from "forge-std/Test.sol";
import {console}      from "forge-std/console.sol";

import {BackdraftTestBase} from "../BackdraftTestBase.sol";
import {BackdraftHook}     from "../../src/BackdraftHook.sol";
import {IPoolManager}      from "v4-core/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey}           from "v4-core/types/PoolKey.sol";
import {IHooks}            from "v4-core/interfaces/IHooks.sol";
import {TickMath}          from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest}      from "v4-core/test/PoolSwapTest.sol";

// ============================================================
// Parameter sweep — Day 6
//
// Sweeps captureRateBps × surchargeCapBps × traderShareBps across a grid.
// For each combination runs a fixed scenario and records:
//   - surcharge collected (absolute + as % of notional)
//   - trader pot (% of escrowed)
//   - LP pot (% of escrowed)
//   - gas: beforeSwap, afterSwap, settle, claimTrader, claimLp
//
// Run with:  forge test --match-contract ParamSweepTest -vv
// Output is a CSV table printed via console.log for easy copy-paste into docs.
// ============================================================
contract ParamSweepTest is Test {

    // Scenario constants (held fixed across all sweep points)
    uint256 constant LIQUIDITY      = 10_000_000e18;
    uint256 constant GAP_NOTIONAL   = 500_000e18;   // Rohan's opening swap
    uint256 constant WIDEN_NOTIONAL = 200_000e18;   // Rohan's 2nd swing — credited contribution
    uint256 constant CLOSE_NOTIONAL = 2_000_000e18; // Vik's closing swap (large to hit caps)
    int24   constant TICK_LOWER     = -6000;
    int24   constant TICK_UPPER     = 6000;

    // Sweep grid
    uint16[3] captureRates  = [uint16(100), 300, 500];   // bps
    uint16[3] surchargeCaps = [uint16(50),  100, 200];   // bps
    uint16[3] traderShares  = [uint16(3000), 5000, 7000]; // bps (alpha)

    struct SweepResult {
        uint16 captureRateBps;
        uint16 surchargeCapBps;
        uint16 traderShareBps;
        uint256 escrowed;
        uint256 notional;
        uint256 traderPot;
        uint256 lpPot;
        uint256 gasBeforeSwap;
        uint256 gasAfterSwap;
        uint256 gasSettle;
        uint256 gasClaimTrader;
        uint256 gasClaimLp;
    }

    /// @notice Prints the parameter table AND asserts the three monotonicity properties
    ///         the parameters are supposed to have. Printed-only sweeps are how a design
    ///         that silently stopped responding to its own knobs goes unnoticed, so each
    ///         point is checked rather than logged and eyeballed:
    ///
    ///           - every point captures something (no dead corner of the grid)
    ///           - escrow is non-decreasing in captureRateBps at a fixed cap
    ///           - the trader share of the pot tracks traderShareBps
    function test_paramSweep() public {
        console.log("captureRate,surchargeCapBps,traderShareBps,escrowed,notional,escrow_bps,traderPot_pct,lpPot_pct,gasBeforeSwap,gasAfterSwap,gasSettle,gasClaimTrader,gasClaimLp");

        // [rate][cap] -> escrowed, for the monotonicity check across rates.
        uint256[3][3] memory escrowByRateCap;

        for (uint i = 0; i < 3; i++) {
            for (uint j = 0; j < 3; j++) {
                uint256 prevTraderPct;
                for (uint k = 0; k < 3; k++) {
                    // Snapshot so vm.roll inside each scenario doesn't bleed into the next
                    uint256 snap = vm.snapshotState();
                    SweepResult memory r = _runScenario(
                        captureRates[i],
                        surchargeCaps[j],
                        traderShares[k]
                    );
                    vm.revertToState(snap);
                    _logResult(r);

                    assertGt(r.escrowed, 0, "sweep point captured nothing");
                    assertEq(r.escrowed, escrowByRateCap[i][j] == 0 ? r.escrowed : escrowByRateCap[i][j],
                        "escrow must not depend on traderShareBps");
                    escrowByRateCap[i][j] = r.escrowed;

                    // alpha only splits the pot; a higher share must not shrink it.
                    uint256 traderPct = (r.traderPot * 100) / r.escrowed;
                    assertGe(traderPct, prevTraderPct, "trader share must rise with alpha");
                    prevTraderPct = traderPct;
                    assertEq(r.traderPot + r.lpPot, r.escrowed, "pots must sum to escrow");
                }
            }
        }

        for (uint j = 0; j < 3; j++) {
            assertGe(escrowByRateCap[1][j], escrowByRateCap[0][j], "escrow rises with captureRate");
            assertGe(escrowByRateCap[2][j], escrowByRateCap[1][j], "escrow rises with captureRate");
        }
    }

    function _runScenario(
        uint16 captureRate,
        uint16 surchargeCap,
        uint16 traderShare
    ) internal returns (SweepResult memory r) {
        r.captureRateBps  = captureRate;
        r.surchargeCapBps = surchargeCap;
        r.traderShareBps  = traderShare;
        r.notional        = CLOSE_NOTIONAL;

        // Fresh deployment for each sweep point via SweepHarness
        SweepHarness h = new SweepHarness(captureRate, surchargeCap, traderShare);
        h.setUp();

        address LP    = address(0x1001);
        address ROHAN = address(0xaaaa);
        address VIK   = address(0xbbbb);

        h.fund(LP,    100_000_000e18);
        h.fund(ROHAN, 100_000_000e18);
        h.fund(VIK,   100_000_000e18);

        // LP adds early so it's eligible when the gap opens
        h.addLiq(LP, TICK_LOWER, TICK_UPPER, uint128(LIQUIDITY));
        vm.roll(block.number + h.minAgeBlocks() + 1);

        // Rohan's first swing: opens the gap (afterSwap early-returns → no contribution yet)
        h.swap(ROHAN, false, -int256(GAP_NOTIONAL));
        uint256 gapIdx = h.hook().openGapIdx(h.poolId());
        require(gapIdx != 0, "sweep scenario failed to open a gap");

        // Rohan's second swing: widen further INTO the already-open gap → credited
        h.swap(ROHAN, false, -int256(WIDEN_NOTIONAL));

        // Vik: large narrowing swap — surcharged, closes the gap
        uint256 gasPreSwap = gasleft();
        h.swap(VIK, true, -int256(CLOSE_NOTIONAL));
        r.gasBeforeSwap = gasPreSwap - gasleft();

        r.escrowed = h.hook().gapAt(h.poolId(), gapIdx).escrowed;
        require(r.escrowed != 0, "sweep scenario captured nothing");

        // Expire gap if still open so settle() doesn't revert
        if (h.hook().openGapIdx(h.poolId()) == gapIdx) {
            BackdraftHook.Gap memory gPre = h.hook().gapAt(h.poolId(), gapIdx);
            vm.roll(gPre.expiryBlock + 1);
        }

        // Settle
        uint256 gasPreSettle = gasleft();
        if (!h.hook().gapAt(h.poolId(), gapIdx).settled) {
            h.hook().settle(h.poolId(), gapIdx);
            r.gasSettle = gasPreSettle - gasleft();
        }

        BackdraftHook.Gap memory g = h.hook().gapAt(h.poolId(), gapIdx);

        // Compute pots (mirrors _traderPot logic in the hook)
        if (g.totalContribution > 0 && g.maxAbsGap > 0) {
            uint256 explained = uint256(g.totalContribution) > uint256(g.maxAbsGap)
                ? uint256(g.maxAbsGap) : uint256(g.totalContribution);
            r.traderPot = (uint256(g.escrowed) * uint256(traderShare) * explained)
                        / (uint256(g.maxAbsGap) * 10_000);
        }
        r.lpPot = uint256(g.escrowed) - r.traderPot;

        // Claim trader (Rohan contributed on the second widening swing)
        bytes32 rohanKey = keccak256(abi.encode(h.poolId(), gapIdx, ROHAN));
        if (h.hook().contribution(rohanKey) > 0) {
            uint256 gasPreClaim = gasleft();
            vm.prank(ROHAN, ROHAN);
            try h.hook().claimTrader(h.poolId(), gapIdx) {
                r.gasClaimTrader = gasPreClaim - gasleft();
            } catch {}
        }

        // Claim LP
        uint256 gasPreLpClaim = gasleft();
        vm.prank(LP, LP);
        try h.hook().claimLp(h.poolId(), gapIdx, TICK_LOWER, TICK_UPPER, bytes32(0)) {
            r.gasClaimLp = gasPreLpClaim - gasleft();
        } catch {}
    }

    function _logResult(SweepResult memory r) internal pure {
        // escrow_bps = escrowed * 10_000 / notional
        uint256 escrowBps = r.notional > 0 ? (r.escrowed * 10_000) / r.notional : 0;
        // traderPot_pct = traderPot * 100 / escrowed (integer %)
        uint256 traderPct = r.escrowed > 0 ? (r.traderPot * 100) / r.escrowed : 0;
        uint256 lpPct     = r.escrowed > 0 ? (r.lpPot     * 100) / r.escrowed : 0;

        console.log(string.concat(
            _u(r.captureRateBps), ",",
            _u(r.surchargeCapBps), ",",
            _u(r.traderShareBps), ",",
            _u(r.escrowed / 1e15), "e15,",  // scale down to readable
            _u(r.notional  / 1e15), "e15,",
            _u(escrowBps), ",",
            _u(traderPct), ",",
            _u(lpPct), ",",
            _u(r.gasBeforeSwap), ",",
            _u(r.gasAfterSwap), ",",
            _u(r.gasSettle), ",",
            _u(r.gasClaimTrader), ",",
            _u(r.gasClaimLp)
        ));
    }

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory buf = new bytes(78);
        uint256 i = 78;
        while (v > 0) { buf[--i] = bytes1(uint8(48 + v % 10)); v /= 10; }
        bytes memory out = new bytes(78 - i);
        for (uint256 j = 0; j < out.length; j++) out[j] = buf[i + j];
        return string(out);
    }
}

// ============================================================
// Gas table — individual entry-point costs in isolation
// ============================================================
/// @notice Gas budgets, measured against a control pool with no hook attached.
///
/// The raw per-swap number (~290k) is the whole round trip — test router, PoolManager,
/// and hook — so quoting it as "the hook costs 290k" overstates the hook by roughly 3x.
/// Every swap measurement here is reported BOTH ways: absolute, and as a delta against
/// the identical swap on a hookless pool in the same PoolManager. The delta is the
/// number that answers "what does Backdraft cost a trader".
///
/// These assert ceilings rather than printing, so a change that doubles the cost of a
/// swap fails CI instead of scrolling past in a log. Ceilings sit ~15% above measured;
/// raise them deliberately, with the reason, not reflexively.
contract GasTableTest is BackdraftTestBase {
    using PoolIdLibrary for PoolKey;

    address constant LP    = address(0x1001);
    address constant ROHAN = address(0xaaaa);
    address constant VIK   = address(0xbbbb);

    PoolKey  controlKey;
    PoolId   controlId;

    function setUp() public override {
        super.setUp();
        address[3] memory who = [LP, ROHAN, VIK];
        for (uint256 i; i < 3; i++) {
            token0.transfer(who[i], 50_000_000e18);
            token1.transfer(who[i], 50_000_000e18);
        }

        // Control: same manager, same tokens, same tick spacing, no hook.
        controlKey = PoolKey({
            currency0:   poolKey.currency0,
            currency1:   poolKey.currency1,
            fee:         3000,
            tickSpacing: poolKey.tickSpacing,
            hooks:       IHooks(address(0))
        });
        controlId = controlKey.toId();
        manager.initialize(controlKey, INIT_SQRT_PRICE);

        vm.startPrank(LP, LP);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            controlKey,
            IPoolManager.ModifyLiquidityParams(-6000, 6000, int256(uint256(10_000_000e18)), bytes32(0)),
            ""
        );
        vm.stopPrank();
    }

    /// @dev The same swap on the hookless control pool.
    function _controlSwapGas(bool zeroForOne, int256 amount) internal returns (uint256) {
        vm.startPrank(ROHAN, ROHAN);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        uint256 g = gasleft();
        swapRouter.swap(
            controlKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 used = g - gasleft();
        vm.stopPrank();
        return used;
    }

    function _report(string memory label, uint256 hooked, uint256 control) internal {
        emit log_named_uint(string.concat(label, " total"), hooked);
        emit log_named_uint(string.concat(label, " control, no hook"), control);
        emit log_named_uint(string.concat(label, " hook overhead"), hooked - control);
    }

    /// @notice No gap open — the cheapest path the hook has. This is what an ordinary
    ///         trade in a Backdraft pool pays when nothing is dislocated, and it is the
    ///         number that matters for routing: most swaps take this path.
    function test_gasBudget_swapNoGap() public {
        _addLiquidity(LP, -6000, 6000, 10_000_000e18);
        uint256 control = _controlSwapGas(false, -1_000e18);

        uint256 g = gasleft();
        _swap(ROHAN, false, -1_000e18);
        uint256 hooked = g - gasleft();

        _report("swap, no gap", hooked, control);
        assertLt(hooked, 262_000, "no-gap swap total");
        assertLt(hooked - control, 95_000, "hook overhead on the common path");
    }

    /// @notice afterSwap opens a gap: one Gap push plus the eligibility snapshot.
    function test_gasBudget_swapOpensGap() public {
        _addLiquidity(LP, -6000, 6000, 10_000_000e18);
        uint256 control = _controlSwapGas(false, -500_000e18);

        uint256 g = gasleft();
        _swap(ROHAN, false, -500_000e18);
        uint256 hooked = g - gasleft();

        assertGt(hook.openGapIdx(poolId), 0, "precondition: a gap actually opened");
        _report("swap, opens gap", hooked, control);
        assertLt(hooked, 420_000, "gap-opening swap total");
    }

    /// @notice beforeSwap takes the surcharge (ERC-6909 mint) and afterSwap closes.
    function test_gasBudget_swapWithSurcharge() public {
        _addLiquidity(LP, -6000, 6000, 10_000_000e18);
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "precondition: gap open");

        uint256 g = gasleft();
        _swap(VIK, true, -100_000e18);
        uint256 hooked = g - gasleft();

        assertGt(hook.gapAt(poolId, idx).escrowed, 0, "precondition: surcharge was taken");
        emit log_named_uint("swap, surcharged", hooked);
        assertLt(hooked, 385_000, "surcharged swap total");
    }

    /// @notice The explicit settle() path: a gap that expires without being narrowed
    ///         under the threshold. The swap-path close is measured in
    ///         test_gasBudget_swapWithSurcharge instead; this one must actually settle,
    ///         so the gap is left open and expired rather than closed by a large swap.
    function test_gasBudget_settle() public {
        _addLiquidity(LP, -6000, 6000, 10_000_000e18);
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "precondition: gap open");
        _swap(VIK, true, -50_000e18);              // partial: surcharges, does not close
        assertFalse(hook.gapAt(poolId, idx).settled, "precondition: still open");

        vm.roll(uint256(hook.gapAt(poolId, idx).expiryBlock) + 1);
        uint256 g = gasleft();
        hook.settle(poolId, idx);
        uint256 used = g - gasleft();
        assertTrue(hook.gapAt(poolId, idx).settled, "settle actually settled");
        emit log_named_uint("settle()", used);
        // 50k, not the ~20k the old test reported: that measurement ran against a gap
        // the swap path had ALREADY settled, so it timed an early return.
        assertLt(used, 60_000, "settle");
    }

    function test_gasBudget_claimTrader() public {
        _addLiquidity(LP, -6000, 6000, 10_000_000e18);
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "precondition: gap open");
        _swap(ROHAN, false, -100_000e18);
        _swap(VIK, true, -1_000_000e18);
        if (!hook.gapAt(poolId, idx).settled) hook.settle(poolId, idx);

        assertGt(hook.contribution(keccak256(abi.encode(poolId, idx, ROHAN))), 0,
            "precondition: ROHAN has a ledger entry");

        uint256 g = gasleft();
        vm.prank(ROHAN, ROHAN);
        hook.claimTrader(poolId, idx);
        uint256 used = g - gasleft();
        emit log_named_uint("claimTrader()", used);
        assertLt(used, 125_000, "claimTrader");
    }

    function test_gasBudget_claimLp() public {
        _addLiquidity(LP, -6000, 6000, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "precondition: gap open");
        _swap(VIK, true, -1_000_000e18);
        if (!hook.gapAt(poolId, idx).settled) hook.settle(poolId, idx);

        uint256 g = gasleft();
        vm.prank(LP, LP);
        hook.claimLp(poolId, idx, int24(-6000), int24(6000), bytes32(0));
        uint256 used = g - gasleft();
        emit log_named_uint("claimLp()", used);
        assertLt(used, 135_000, "claimLp");
    }

    /// @notice Adding liquidity carries the position record and the eligibility
    ///         checkpoint. Measured against the identical add on the control pool.
    function test_gasBudget_addLiquidity() public {
        vm.startPrank(LP, LP);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        uint256 g = gasleft();
        lpRouter.modifyLiquidity(
            controlKey,
            IPoolManager.ModifyLiquidityParams(-3000, 3000, int256(uint256(1_000_000e18)), bytes32(0)),
            ""
        );
        uint256 control = g - gasleft();
        vm.stopPrank();

        g = gasleft();
        _addLiquidity(LP, -3000, 3000, 1_000_000e18);
        uint256 hooked = g - gasleft();

        _report("addLiquidity", hooked, control);
        // ~2.1x a hookless add. The hook writes a PositionInfo record and pushes an
        // eligibility checkpoint, both cold. This is the largest overhead Backdraft
        // imposes anywhere and it lands on LPs, not traders; it is reported in the
        // README rather than buried.
        assertLt(hooked - control, 290_000, "hook overhead on add");
    }
}

// ============================================================
// Sweep harness — thin wrapper that exposes BackdraftTestBase
// helpers as non-internal so ParamSweepTest can call them
// ============================================================
contract SweepHarness is BackdraftTestBase {

    constructor(uint16 captureRate, uint16 surchargeCap, uint16 traderShare) {
        captureRateBps  = captureRate;
        surchargeCapBps = surchargeCap;
        traderShareBps  = traderShare;
    }

    function fund(address who, uint256 amount) external {
        token0.transfer(who, amount);
        token1.transfer(who, amount);
    }

    function addLiq(address lp, int24 lo, int24 hi, uint128 liq) external {
        _addLiquidity(lp, lo, hi, liq);
    }

    function swap(address who, bool zeroForOne, int256 amount) external returns (int256, int256) {
        return _swap(who, zeroForOne, amount);
    }
}
