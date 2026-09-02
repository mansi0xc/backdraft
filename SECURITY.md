# Static analysis

Tool: Slither 0.11.6, solc 0.8.26.

```bash
forge build --build-info
slither . --ignore-compile --filter-paths "lib/|test/|script/"
```

Baseline was 15 findings. Six remain, all one detector, all the same false positive.

| Detector | Impact | Before | After |
|---|---|---|---|
| `reentrancy-no-eth` | Medium | 1 | 0 |
| `reentrancy-events` | Low | 4 | 0 |
| `unused-return` | Medium | 10 | 6 |
| **Total** | | **15** | **6** |

## Fixed

**`reentrancy-no-eth` in `beforeSwap`.** `poolManager.mint` ran before the gap's escrow
bookkeeping — the currency-invariant check and `gp.escrowed +=`. Not exploitable: this
executes inside the PoolManager's lock and `mint` calls back into nothing. Reordered
anyway, because "not reachable today" is a weaker guarantee than "the writes happen
first," and the second one survives a refactor.

**`reentrancy-events` ×4** (`claimLp`, `claimTrader`, `sweepUnclaimed`, `beforeSwap`).
Events were emitted after the external call. Same reasoning: ordering hygiene, not a
vulnerability. An observer reconstructing state from logs now sees the credit recorded
before the transfer that satisfies it, which matches the order of the storage writes.

**`unused-return` ×4.** Two `poolManager.unlock` call sites and two `poolManager.donate`
call sites, annotated with the reason rather than silenced blindly:

- `unlock()` returns `unlockCallback`'s return data. This hook's `unlockCallback`
  returns `""` unconditionally, so there is nothing to check.
- `donate()` returns the delta it created. The preceding `burn` produced the offsetting
  negative delta for exactly the same amount, and the PoolManager reverts on unlock if
  the two do not sum to zero. The settlement check is strictly stronger than any
  assertion we could write at the call site. `donate` also reverts outright when the
  pool has no in-range liquidity, which is the one case where a swept remainder has
  nowhere to go.

## Remaining, and why

All six are `unused-return` on **tuple destructuring**, which Slither reports whenever a
multi-return call has ignored components:

| Site | Call |
|---|---|
| `BackdraftHook.beforeSwap` | `(uint160 sqrtPriceX96, int24 tick,,) = StateLibrary.getSlot0(...)` |
| `BackdraftHook.afterSwap` | `(, int24 tick,,) = StateLibrary.getSlot0(...)` |
| `BackdraftHook._isInRange` | `(, int24 tickNow,,) = StateLibrary.getSlot0(...)` |
| `SplitV3Reference._spotTick` | `(, t,,,,,) = IUniswapV3PoolMinimal(pool).slot0()` |
| `SplitV3Reference._twapTick` | `(int56[] cum, ) = observe(ago)` |
| `OwnPoolEmaReference.update` | `(, tick,,) = poolManager.getSlot0(...)` |

Reading the tick and discarding the protocol fee and LP fee is the intended use of
`getSlot0`. There is no return value being dropped on the floor; the detector cannot
distinguish "ignored tuple component" from "ignored status code." These are left
unsuppressed on purpose — a report with zero findings and six `slither-disable`
directives is less informative than a report with six findings and a reason for each.

## Not covered by static analysis

The defects that actually mattered in this build were economic, not structural:
attribution direction, splitting discounts, escrow currency invariants, LP eligibility
denominators. Slither found none of them, and would not. See `CHANGES.md` for that
record and the tests that pin each fix.
