# Task 3 — exogenous capture: open pre-existing gaps in `beforeSwap`

Applies **on top of tasks 1 and 2**. Base: `test` @ `8ec2cd2` + task 1 + task 2.
Built and run with `forge 1.5.1-stable`, `solc 0.8.26`.

## The rule, in one sentence

**A gap that already exists when a swap arrives was not created by that swap, so it is
opened before the swap runs — and the swap that closes it pays.**

Together with task 2's rule (credit follows direction at entry), that is the whole
mechanism, and both sentences are demo-day answers.

## The bug

Gap detection lived only in `afterSwap`. On the pure exogenous path — external market
moves, nobody trades this pool, an arbitrageur arrives and closes the entire gap in one
swap — `beforeSwap` returned early because `openGapIdx == 0`, and by the time `afterSwap`
ran the pool had already been corrected, so the residual was below threshold and nothing
opened either. Measured on the unpatched branch:

```
openGapIdx before arb: 0
pool tick after arb:   589
openGapIdx after arb:  1        <- opened too late, on the residual
escrow c0 gained:      0
escrow c1 gained:      0
```

Zero captured. The only case that produced anything was a *partial* close leaving the gap
still above 65 ticks — but profitable arbitrage closes to the no-arb band in one shot, so
the first and largest closing swap always escaped.

"Backdraft handles exogenous LVR too" is the differentiator over Detox / WTH / ArbHook.
It did not hold. The test named `test_EndToEnd_ExogenousGap_AllToLPs` passed the whole
time because of an `if (escrowed == 0) return;` on the way to its assertions.

## The fix

`beforeSwap`, replacing the early return:

```solidity
uint256 idx = openGapIdx[id];

if (idx == 0) {
    if (GapMath.abs(gapBefore) > c.gapThresholdTicks) {
        _openGap(id, refTick, tick, gapBefore);   // pre-existing -> open pre-swap
        idx = openGapIdx[id];
    } else {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
// ... existing surcharge path now runs for exogenous gaps too
```

The classification is **structural, not heuristic** — there is no guessing about intent:

| Gap at swap entry | Gap at swap exit | Cause | Opened in |
|---|---|---|---|
| above threshold | — | pre-existing (external) | `beforeSwap` |
| below threshold | above threshold | this swap | `afterSwap` |

`afterSwap`'s open branch is unchanged in behaviour and now carries a comment saying why
reaching it means the gap is endogenous.

Nothing else was needed. The gap opens with an empty ledger, so if no swap widens it
before it closes, `explained = 0` and settlement routes 100% to LPs by the rule that was
already there. Task 2's `_credit` handles the mixed case — an exogenous gap that a trader
then widens further credits only the trader's increment, leaving the external portion
unexplained and with the LPs.

## Apply

```bash
git checkout test                       # tasks 1 and 2 already committed
git apply --check task3-exogenous.patch
git apply task3-exogenous.patch
forge test --no-match-path "test/fork/*"
```

Or copy over, preserving paths:

```
src/BackdraftHook.sol             (modified — ~26 lines in beforeSwap)
test/exogenous/Exogenous.t.sol    (NEW — create test/exogenous/ first)
```

No existing test needed changing. All 64 from task 2 still pass.

## The observable that proves it

`Gap.tickAtOpen` distinguishes the two paths without any instrumentation:

* opened in `beforeSwap` -> records the **pre-swap** tick
* opened in `afterSwap`  -> records the **post-swap** tick

`test_ExogenousGapOpensOnPreSwapTick` and `test_EndogenousGapStillOpensOnPostSwapTick`
assert exactly this, which is how the tests prove the two paths did not collapse into
one. Under the mutation that restores the old code, the first fails with
`589 != 0` — the same 589 from the original probe.

## New tests — `test/exogenous/Exogenous.t.sol` (9)

| Test | Pins |
|---|---|
| `test_PureExogenous_SingleSwapClose_IsSurcharged` | **the headline** — one-swap close pays |
| `test_ExogenousGapOpensOnPreSwapTick` | detected before the arbitrage, not after |
| `test_EndogenousGapStillOpensOnPostSwapTick` | endogenous path not collapsed into it |
| `test_PureExogenous_EmptyLedger_AllToLps` | LP receives ~100% of escrow |
| `test_PureExogenous_ArbitrageurClaimsNothing` | `claimTrader` reverts `"n/a"` |
| `test_MixedGap_ExternalPortionStaysWithLps` | `explained < 1` on partly-external gaps |
| `test_SubThresholdPreExistingGapDoesNotOpen` | blindness under 65 ticks is deliberate |
| `test_FrozenOracleDoesNotOpenExogenousGap` | frozen guard produces inaction (§6) |
| `testFuzz_ExogenousAlwaysCapturedAndAllToLps` | holds for any above-threshold dislocation |

One correction I made to my own test while writing it: I expected `claimTrader` to revert
`"nothing"`; it reverts `"n/a"`, because on an exogenous gap there is no trader pot at
all rather than an empty share of one. The stronger statement, so the test now asserts
that.

## Verification

```
73 passed, 0 failed        (was 64 after task 2)
```

Measured capture on the pure exogenous path, same scenario that produced zero before:

```
captured (currency1):  300.0e18 wei
totalContribution:     0          -> explained = 0 -> 100% to LPs
maxAbsGap:             200
```

**Two mutation tests**, each reverted individually:

| Mutation | Result |
|---|---|
| restore the `beforeSwap` early return (old code) | **5 failed** — incl. `single-swap close must be surcharged: 0 <= 0` and `pre-swap tick: 589 != 0` |
| open pre-swap gaps regardless of threshold | **2 failed** — `endogenous gap must open: 0 <= 0`, `no currency1 surcharge: 3e17 != 0` |

The second mutation matters as much as the first: it proves the threshold check is doing
real work and that removing it would collapse the endogenous path (every swap would find
a "pre-existing" gap) and start charging inside measurement noise.

Reproduce before committing:

```bash
# comment out the _openGap block in beforeSwap's idx == 0 branch, leaving the return
forge test --match-path "test/exogenous/*"   # must FAIL, 5 tests
git checkout src/BackdraftHook.sol
forge test --match-path "test/exogenous/*"   # must PASS
```

## Gas

```
swap (no gap):                    186,129   (+245 vs task 2)
swap (opens gap, endogenous):     291,873   (+281)
swap (surcharge + closes gap):    196,792   (+6)
exogenous close (opens in beforeSwap + surcharges): 359,854   [new path]
```

The exogenous path is the expensive one because a single swap now does gap-open,
surcharge, and gap-close. It is also the path that previously did nothing at all, so the
comparison is against a hook that wasn't working. Still using the **mock** oracle — real
`SplitV3Reference` adds ~74k per read, two reads per swap. The single-read optimisation
the README claims is still unwritten.

## What this unlocks for the demo

Demo B is now real, and it is the one no competitor will have:

1. Set the reference 200 ticks away. Pool untouched, nobody has traded.
2. Vik swaps once and closes the whole gap.
3. `GapOpened` fires **before** `Surcharged`, both in the same transaction.
4. No `Contributed` event — nothing in this pool caused the gap.
5. Settle. LP claims and receives ~100% of the escrow. Vik's `claimTrader` reverts.

The event ordering inside one transaction is the proof, and it is visible in a Foundry
trace. Point at it.

## Still open

4. **Splitting discount.** Eight legs pay 36% of one leg (3840 vs 1380). Price the
   surcharge on `maxAbsGap` rather than the prevailing gap. The field exists and, after
   tasks 2 and 3, is clean. This is now the last mechanism bug.
5. **Twelve remaining escape hatches**, plus `ParamSweep`'s `catch {}` blocks hiding
   `gasClaimTrader = 0` on all 27 rows.
6. **Solvency invariant still discharges at `settle()`**, not at claim — blind to
   post-settlement theft.
7. **README claims a two-stage read optimisation that does not exist.** Write it or
   delete the sentence. Same class of error as the task 1 commit message.
