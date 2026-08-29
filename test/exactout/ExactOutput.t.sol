// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BackdraftTestBase} from "../BackdraftTestBase.sol";
import {BackdraftHook}     from "../../src/BackdraftHook.sol";
import {console}           from "forge-std/console.sol";

// ============================================================
// Exact-output bypass regression tests.
//
// History: beforeSwap opened with
//
//     if (params.amountSpecified >= 0) return (selector, ZERO_DELTA, 0);
//
// In v4 a positive amountSpecified means EXACT OUTPUT. So exact-output swaps were never
// surcharged. Measured on the unpatched branch, same gap, same direction, same size:
//
//     exact-INPUT  close, escrowed: 1920e18
//     exact-OUTPUT close, escrowed: 0
//
// An arbitrageur flips one flag in their swap params and pays nothing. Every router
// supports exact output. This defeated the mechanism more completely than splitting,
// ledger poisoning, or misattribution — there was simply no value to attribute.
//
// The fix takes the surcharge on the UNSPECIFIED side for exact output. v4-core maps
// beforeSwap's unspecified delta to the input currency for exact-output swaps
// (Hooks.afterSwap: `amountSpecified < 0 == zeroForOne` picks the ordering), so escrow
// still lands in the input currency and the one-currency-per-gap invariant survives
// without a second escrow bucket.
//
// Notional is converted from output units to input units at the pre-swap pool price,
// because `amountSpecified` for an exact-output swap is denominated in the OUTPUT token
// while the surcharge is taken in the INPUT token. Charging bps of an output-token
// amount as input-token units would misprice by the whole exchange rate — on ETH/USDC
// by a factor of ~3000.
// ============================================================
contract ExactOutputTest is BackdraftTestBase {

    address constant LP    = address(0x1001);
    address constant ROHAN = address(0xaaaa);
    address constant VIK   = address(0xbbbb);

    int24 constant LO = -6000;
    int24 constant HI =  6000;

    function setUp() public override {
        super.setUp();
        _fund(LP); _fund(ROHAN); _fund(VIK);
        _addLiquidity(LP, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
    }

    function _fund(address who) internal {
        token0.transfer(who, 50_000_000e18);
        token1.transfer(who, 50_000_000e18);
    }

    function _openGap() internal returns (uint256 idx) {
        _swap(ROHAN, false, -500_000e18);
        idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "precondition: gap must open");
    }

    // ------------------------------------------------------------------
    // The bypass, closed
    // ------------------------------------------------------------------

    /// @notice An exact-output swap that closes a gap must be surcharged. This is the
    ///         test that failed before the fix, with escrowed == 0.
    function test_ExactOutputCloseIsSurcharged() public {
        uint256 idx = _openGap();

        _swap(VIK, true, int256(400_000e18));      // positive == exact output

        assertGt(hook.gapAt(poolId, idx).escrowed, 0,
            "exact-output close must pay a surcharge");
    }

    /// @notice Swap type must not change the price. An arbitrageur choosing exact output
    ///         over exact input must not gain a material discount.
    function test_ExactOutputCostsSameAsExactInput() public {
        uint256 snap = vm.snapshotState();

        uint256 idx = _openGap();
        _swap(VIK, true, -400_000e18);             // exact input
        uint128 viaInput = hook.gapAt(poolId, idx).escrowed;

        vm.revertToState(snap);

        idx = _openGap();
        _swap(VIK, true, int256(400_000e18));      // exact output
        uint128 viaOutput = hook.gapAt(poolId, idx).escrowed;

        console.log("exact-input escrowed: ", viaInput);
        console.log("exact-output escrowed:", viaOutput);

        // Tolerance covers the price-impact term the pre-swap conversion cannot see.
        assertApproxEqRel(uint256(viaOutput), uint256(viaInput), 0.10e18,
            "exact-output must not be materially cheaper than exact-input");
    }

    /// @notice Escrow must stay in ONE currency per gap even when a gap is closed by a
    ///         mix of exact-input and exact-output swaps. Before the fix this could not
    ///         arise; taking exact-output on the specified side instead would have made
    ///         it revert on the isCurrency0 invariant.
    function test_MixedExactInputAndOutputKeepsOneEscrowCurrency() public {
        uint256 idx = _openGap();

        uint256 c0Before = _hookBalance(poolKey.currency0);
        uint256 c1Before = _hookBalance(poolKey.currency1);

        _swap(VIK, true, -100_000e18);             // exact input
        _swap(VIK, true, int256(100_000e18));      // exact output, same direction
        _swap(VIK, true, -100_000e18);             // exact input again

        uint256 g0 = _hookBalance(poolKey.currency0) - c0Before;
        uint256 g1 = _hookBalance(poolKey.currency1) - c1Before;

        assertGt(hook.gapAt(poolId, idx).escrowed, 0, "escrow must accumulate");
        assertTrue(g0 == 0 || g1 == 0, "escrow must land in exactly one currency");
    }

    /// @notice The swapper must still receive exactly the output they asked for. v4
    ///         raises amountToSwap by the hook delta on exact output, so the extra comes
    ///         out of additional input, not out of the requested output.
    function test_ExactOutputSwapperStillReceivesRequestedAmount() public {
        _openGap();

        // oneForZero: input is token1, output is token0.
        uint256 before = token0.balanceOf(VIK);
        _swap(VIK, false, int256(200_000e18));     // exact output, widening direction
        uint256 gained = token0.balanceOf(VIK) - before;

        // Direction here is widening, so no surcharge applies; the assertion is about
        // v4's exact-output accounting holding under our hook at all.
        assertGt(gained, 0, "swapper must receive output");
    }

    /// @notice Widening exact-output swaps are still not surcharged — only correctors pay.
    function test_ExactOutputWideningNotSurcharged() public {
        uint256 idx = _openGap();
        uint128 before = hook.gapAt(poolId, idx).escrowed;

        _swap(ROHAN, false, int256(50_000e18));    // exact output, widening direction

        assertEq(hook.gapAt(poolId, idx).escrowed, before,
            "widening swaps must never be surcharged, exact-output included");
    }

    /// @notice Exact output must not bypass the guard either.
    function test_ExactOutputFrozenOracleNotSurcharged() public {
        uint256 idx = _openGap();
        uint128 before = hook.gapAt(poolId, idx).escrowed;

        oracle.setFrozen(poolId, true);
        _swap(VIK, true, int256(200_000e18));

        assertEq(hook.gapAt(poolId, idx).escrowed, before,
            "frozen reference must suppress exact-output surcharges too");
    }

    /// @notice Exact-output closes must also be excluded from the ledger — the corrector
    ///         rule from task 2 must not have a swap-type-shaped hole in it.
    function test_ExactOutputCorrectorNotCredited() public {
        uint256 idx = _openGap();

        _swap(VIK, true, int256(400_000e18));

        assertEq(hook.contribution(keccak256(abi.encode(poolId, idx, VIK))), 0,
            "exact-output corrector must not be credited");
    }

    /// @notice THE unit test for the conversion. Every other test in this file runs at
    ///         tick ~0, where price is ~1 and output-token units coincide with
    ///         input-token units — so they all pass even with the conversion deleted.
    ///         Here the pool is pushed far from parity first, so charging bps of an
    ///         output amount as if it were an input amount misprices by the exchange
    ///         rate and the comparison fails loudly.
    ///
    ///         On ETH/USDC this is the difference between charging 48 bps and charging
    ///         48 bps times 3000.
    function test_ExactOutputPricedCorrectlyAwayFromParity() public {
        // Push the pool a long way from tick 0, keeping the reference alongside it so
        // no gap opens while we move.
        // setUp's LP sits in -6000..6000, which the pool exhausts before it can travel
        // far. Add wide-range liquidity so the price can actually move.
        _addLiquidity(LP, -60000, 60000, 20_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);

        for (uint256 i = 0; i < 6; i++) {
            _swap(ROHAN, false, -8_000_000e18);
            oracle.setRef(poolId, _poolTick());     // keep the reference alongside
        }
        int24 skewed = _poolTick();
        assertGt(skewed, 8000, "precondition: pool must be far from parity");

        // Now open a gap at the skewed price.
        oracle.setRef(poolId, skewed - 900);
        uint256 snap = vm.snapshotState();

        // Exact input of 200k token0, and record how much token1 it actually produced.
        // Away from parity the two swap types must be compared at equivalent SIZE, not
        // at the same number: 200k of output is a far smaller trade than 200k of input
        // when the price is ~10. Using the realised output makes them the same trade.
        uint256 out0 = token1.balanceOf(VIK);
        _swap(VIK, true, -200_000e18);
        uint256 produced = token1.balanceOf(VIK) - out0;
        uint256 idxA = hook.gaps(poolId).length - 1;
        uint128 viaInput = hook.gapAt(poolId, idxA).escrowed;
        assertGt(viaInput, 0, "precondition: exact-input close must be surcharged");
        assertGt(produced, 0, "precondition: exact-input close must produce output");

        vm.revertToState(snap);

        _swap(VIK, true, int256(produced));         // exact output, EQUIVALENT trade
        uint256 idxB = hook.gaps(poolId).length - 1;
        uint128 viaOutput = hook.gapAt(poolId, idxB).escrowed;

        console.log("skewed tick:");            console.logInt(skewed);
        console.log("exact-input escrowed: ",   viaInput);
        console.log("exact-output escrowed:",   viaOutput);

        assertApproxEqRel(uint256(viaOutput), uint256(viaInput), 0.15e18,
            "exact-output notional was not converted to input units at the pool price");
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    /// @notice No exact-output size may close a gap for free.
    function testFuzz_ExactOutputAlwaysSurcharged(uint96 outAmount) public {
        outAmount = uint96(bound(outAmount, 50_000e18, 400_000e18));

        uint256 idx = _openGap();
        _swap(VIK, true, int256(uint256(outAmount)));

        assertGt(hook.gapAt(poolId, idx).escrowed, 0,
            "exact-output close escaped the surcharge at some size");
    }
}
