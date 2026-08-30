// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test}         from "forge-std/Test.sol";
import {console}      from "forge-std/console.sol";

import {BackdraftTestBase} from "../BackdraftTestBase.sol";
import {BackdraftHook}     from "../../src/BackdraftHook.sol";
import {IPoolManager}      from "v4-core/interfaces/IPoolManager.sol";
import {PoolId}            from "v4-core/types/PoolId.sol";

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

    function test_paramSweep() public {
        console.log("captureRate,surchargeCapBps,traderShareBps,escrowed,notional,escrow_bps,traderPot_pct,lpPot_pct,gasBeforeSwap,gasAfterSwap,gasSettle,gasClaimTrader,gasClaimLp");

        for (uint i = 0; i < 3; i++) {
            for (uint j = 0; j < 3; j++) {
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
                }
            }
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
        if (gapIdx == 0) return r; // gap didn't open — skip

        // Rohan's second swing: widen further INTO the already-open gap → credited
        h.swap(ROHAN, false, -int256(WIDEN_NOTIONAL));

        // Vik: large narrowing swap — surcharged, closes the gap
        uint256 gasPreSwap = gasleft();
        h.swap(VIK, true, -int256(CLOSE_NOTIONAL));
        r.gasBeforeSwap = gasPreSwap - gasleft();

        r.escrowed = h.hook().gapAt(h.poolId(), gapIdx).escrowed;
        if (r.escrowed == 0) return r;

        // Expire gap if still open so settle() doesn't revert
        if (h.hook().openGapIdx(h.poolId()) == gapIdx) {
            BackdraftHook.Gap memory gPre = h.hook().gapAt(h.poolId(), gapIdx);
            vm.roll(gPre.expiryBlock + 1);
        }

        // Settle
        uint256 gasPreSettle = gasleft();
        try h.hook().settle(h.poolId(), gapIdx) {
            r.gasSettle = gasPreSettle - gasleft();
        } catch { return r; }

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
contract GasTableTest is BackdraftTestBase {

    address constant LP    = address(0x1001);
    address constant ROHAN = address(0xaaaa);
    address constant VIK   = address(0xbbbb);

    function setUp() public override {
        super.setUp();
        token0.transfer(LP,    50_000_000e18);
        token1.transfer(LP,    50_000_000e18);
        token0.transfer(ROHAN, 50_000_000e18);
        token1.transfer(ROHAN, 50_000_000e18);
        token0.transfer(VIK,   50_000_000e18);
        token1.transfer(VIK,   50_000_000e18);
    }

    /// @notice Swap with no gap open — baseline (just hook overhead with early return).
    function test_gas_swapNoGap() public {
        _addLiquidity(LP, -6000, 6000, 10_000_000e18);
        uint256 g = gasleft();
        _swap(ROHAN, false, -1_000e18);
        console.log("gas swap (no gap):", g - gasleft());
    }

    /// @notice Swap that opens a gap (afterSwap opens new gap).
    function test_gas_swapOpensGap() public {
        _addLiquidity(LP, -6000, 6000, 10_000_000e18);
        uint256 g = gasleft();
        _swap(ROHAN, false, -500_000e18);
        console.log("gas swap (opens gap):", g - gasleft());
    }

    /// @notice Narrowing swap that collects surcharge (beforeSwap mints ERC-6909).
    function test_gas_swapWithSurcharge() public {
        _addLiquidity(LP, -6000, 6000, 10_000_000e18);
        _swap(ROHAN, false, -500_000e18); // open gap
        uint256 g = gasleft();
        _swap(VIK, true, -100_000e18);   // surcharged
        console.log("gas swap (surcharge + closes gap):", g - gasleft());
    }

    /// @notice settle() on a closed gap.
    function test_gas_settle() public {
        _addLiquidity(LP, -6000, 6000, 10_000_000e18);
        _swap(ROHAN, false, -500_000e18);
        _swap(VIK, true, -1_000_000e18); // close gap

        uint256 gapIdx = 1; // first real gap
        uint256 g = gasleft();
        if (!hook.gapAt(poolId, gapIdx).settled) hook.settle(poolId, gapIdx);
        console.log("gas settle():", g - gasleft());
    }

    /// @notice claimTrader() — paying out a contributor.
    function test_gas_claimTrader() public {
        _addLiquidity(LP, -6000, 6000, 10_000_000e18);
        _swap(ROHAN, false, -500_000e18); // opens gap, ROHAN is tx.origin
        uint256 gapIdx = hook.openGapIdx(poolId);
        if (gapIdx == 0) return;

        // Second widening swap credits ROHAN
        _swap(ROHAN, false, -100_000e18);
        _swap(VIK, true, -1_000_000e18); // close + surcharge

        if (!hook.gapAt(poolId, gapIdx).settled) hook.settle(poolId, gapIdx);

        bytes32 rohanKey = keccak256(abi.encode(poolId, gapIdx, ROHAN));
        if (hook.contribution(rohanKey) == 0) return;

        uint256 g = gasleft();
        vm.prank(ROHAN, ROHAN);
        hook.claimTrader(poolId, gapIdx);
        console.log("gas claimTrader():", g - gasleft());
    }

    /// @notice claimLp() — LP pot payout including ERC-6909 burn+take via unlock.
    function test_gas_claimLp() public {
        _addLiquidity(LP, -6000, 6000, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);

        _swap(ROHAN, false, -500_000e18);
        uint256 gapIdx = hook.openGapIdx(poolId);
        if (gapIdx == 0) return;

        _swap(VIK, true, -1_000_000e18);
        if (!hook.gapAt(poolId, gapIdx).settled) hook.settle(poolId, gapIdx);

        uint256 g = gasleft();
        vm.prank(LP, LP);
        hook.claimLp(poolId, gapIdx, int24(-6000), int24(6000), bytes32(0));
        console.log("gas claimLp():", g - gasleft());
    }

    /// @notice addLiquidity with hook tracking overhead.
    function test_gas_addLiquidity() public {
        uint256 g = gasleft();
        _addLiquidity(LP, -6000, 6000, 10_000_000e18);
        console.log("gas addLiquidity (hook):", g - gasleft());
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
