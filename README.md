<div align="center">

# Backdraft

**A Uniswap v4 hook that stops the pool from handing back money it is already holding.**

UHI10 · HK-UHI10-1088 · Mansi & Roshan

</div>

---

## The pool is sitting on money

A pool with 100 ETH and 300,000 USDC quotes ETH at $3,000. Rohan buys 10 ETH.

| | ETH | USDC | Value at the true price of $3,000 |
|---|---|---|---|
| Start | 100 | 300,000 | $600,000 |
| **After Rohan buys** | 90 | 333,333 | **$603,333** |
| After Vik arbs it back | 100 | 300,000 | $600,000 |

Rohan paid $33,333 for 10 ETH worth $30,000. He overpaid by $3,333, and for one moment
the pool **held** that $3,333. Then the pool quoted $3,704 while Binance still quoted
$3,000, Vik the arbitrageur sold 10 ETH into it, and the $3,333 walked out the door —
most of it onward to a block builder in the priority fee.

Nobody stole anything. The pool simply had no way to notice it was quoting a stale price,
and no mechanism to charge for the privilege of correcting it.

**Backdraft is that mechanism.** It never runs the arbitrage. It never fetches a price
off-chain. It notices the gap, prices the swap that closes it, and splits the proceeds
between the traders who created the gap and the LPs who funded it.

---

## How it works, in one worked example

The hook reads a reference price, and when the pool drifts more than
`gapThresholdTicks` (65) away from it, a **gap** opens. While a gap is open the hook
keeps a **contribution ledger**: every swap that widens the gap is credited for the
ticks it added. Every swap that narrows it pays a **surcharge**, escrowed in the hook.
When the gap closes, the escrow is split.

Parameters below: `captureRateBps = 500`, `surchargeCapBps = 200`, `traderShareBps = 5000`.

### Endogenous — a trade moved the pool

Pool at tick 0. Reference at tick 0. Everything fair.

| | Swap | Notional | Tick after | gap | Δgap | Hook action |
|---|---|---|---|---|---|---|
| **A** | Rohan buys | $1.2M | +180 | 0 → 180 | **+180** | gap opens · credit Rohan **180** |
| **B** | retail buys | $80k | +195 | 180 → 195 | **+15** | credit retail **15** |
| **C** | retail sells | $20k | +185 | 195 → 185 | −10 | surcharge **$19.50** |
| **D** | Vik sells | $600k | +15 | 185 → 15 | −170 | surcharge **$585.00** · gap closes |

The surcharge rate comes from the widest the gap ever reached (`maxAbsGap` = 195 ticks),
so splitting a close into small pieces buys no discount:
`195 × 500 / 1e8` = **9.75 bps**, under the 200 bps cap.

**Settlement.** The ledger explains the full gap (`180 + 15 = 195 = maxAbsGap`), so the
trader share applies in full:

| | Amount | Why |
|---|---|---|
| Escrowed | **$604.50** | C + D |
| → Traders | $302.25 | `traderShareBps` = 50%, ledger explains 100% of the gap |
| &nbsp;&nbsp;&nbsp;&nbsp;Rohan | **$279.00** | 180 / 195 of the trader pot |
| &nbsp;&nbsp;&nbsp;&nbsp;retail | **$23.25** | 15 / 195 |
| → LPs | **$302.25** | in-range, and holding since before the gap opened |

Vik closed the gap and earns nothing from the ledger. Correcting a price is not a
contribution to creating one.

### Exogenous — the world moved and the pool went stale

Same pool. No trade happens. The reference jumps 195 ticks; the pool sits still. Vik
arbs the dislocation with a $600k swap.

Identical code path. The gap opens on the pre-swap tick, Vik pays the same **$585.00**
surcharge — and the ledger is **empty**, because no swap in this pool caused the
dislocation. `explained = 0`, the trader pot is zero, and **100% goes to LPs** as
compensation for loss-versus-rebalancing.

> **This is the design's one real elegance.** There is no `if (exogenous)` branch
> anywhere in the hook. An empty ledger *is* the attribution result. The two regimes
> everyone else special-cases fall out of the same arithmetic.

### And a fee that leans the right way

On a dynamic-fee pool, a gap-closing swap can also receive a discounted LP fee. The
discount is bounded by the surcharge collected on that same swap, so a closer never pays
less than a widener: at swap D above, the fee drops from 0.30% to 0.2027% and Vik's
all-in cost is $1,800.01 against the $1,800.00 a widener pays on the same notional.
Corrective flow gets a nudge, never a subsidy.

---

## Where the reference comes from

A pool cannot detect its own staleness from its own price history — when the market
moves and the pool goes stale, the pool's history reports no deviation, because it *is*
the stale price. Our first design was an EMA of the pool's own ticks. It is **16.7×**
less accurate than what ships, and worse, it would have paid a rebate to the arbitrageur
draining its own LPs.

So the reference is external, and which external source turned out to be the interesting
question:

| Source | Mean error vs Binance | Liquidity share |
|---|---|---|
| **v3 0.01%** — most-traded | **3.48 bps** | 10% |
| v3 0.05% — deepest | 4.18 bps | 78% |
| v3 0.30% | 13.82 bps | 12% |
| v3 1.00% | 50.90 bps | 0.2% |

**The freshest source is not the deepest.** Accuracy is inverse to liquidity and
monotone in trade count — the cheapest tier is the arbitrageurs' first stop, so it is
corrected most often. Blending sources by liquidity weight, which is standard oracle
practice, therefore selects the *staler* price and gains **0.000 bps** of accuracy.

So Backdraft splits the two jobs: **price from the fast pool, sanity check from the deep
one.** The deep pool's spot-vs-TWAP disagreement is the manipulation signal, and when it
fires the hook raises the surcharge rather than switching itself off — because the blocks
where spot and TWAP disagree are exactly the blocks a fast exogenous move is happening,
and a hook that freezes then is a hook that freezes during the events it exists for.
That decision is worth **37–91%** of capturable value depending on the pool.

<sub>Full method, all three windows, every rejected alternative, and the caveats:
**[APPENDIX.md](./APPENDIX.md)**.</sub>

---

## What it costs

Measured against an identical pool with no hook attached, in the same `PoolManager`, so
the number is the hook's cost and not the test harness's.

| Path | Total | No hook | **Backdraft** |
|---|---|---|---|
| Swap, no gap open | 227,825 | 146,370 | **+81,455** |
| Swap, opens a gap | 361,908 | 146,518 | +215,390 |
| Swap, surcharged | 354,626 | 151,974 | +202,652 |
| `addLiquidity` | 476,867 | 223,208 | +253,659 |
| `settle()` | 50,781 | — | — |
| `claimTrader()` | 106,797 | — | — |
| `claimLp()` | 116,781 | — | — |

The common path — a swap when nothing is dislocated, which is most swaps — costs about
**81k** over a plain pool. The heaviest cost in the system is not on traders at all:
adding liquidity roughly doubles, because the hook writes a position record and an
eligibility checkpoint. A mechanism built to pay LPs charges LPs the most gas. Ceilings
are asserted in `GasTableTest`, so a change that doubles a path fails the suite.

Reference reads cost 66k–77k gas, measured against mainnet.

---

## What we measured

Every design parameter came from a measurement rather than a guess, across three mainnet
windows (14 Jul, 24 Jul, 19–21 Aug 2026) with Binance as ground truth. The headlines:

- **The 65-tick threshold** comes from measured reference error, not from taste.
- **Blending sources buys nothing.** 0.000 bps of accuracy, at 3× the read cost.
- **A TWAP is a bad reference and a good detector.** Error grows monotonically with
  window length — 4.63 bps at 60 s, 60.32 bps at 2 hours — so it guards, never prices.
- **Pricing divergence instead of freezing on it** moves 37–91% of dislocation value
  back into scope.
- **Backdraft is meaningful on thin pools, not busy ones.** On a pool that is already
  the price-setter, most dislocation value never clears 65 ticks. That is a positioning
  statement, and it is measured rather than asserted.

Every number is reproducible:
**[backdraft-python-scripts](https://github.com/mansi0xc/backdraft-python-scripts)** —
scripts and committed outputs. Method, tables, and caveats:
**[APPENDIX.md](./APPENDIX.md)**.

---

## What it does not do

- **It does not eliminate arbitrage.** Price discovery still works; the change is who
  keeps the proceeds. This is capture, not prevention.
- **It cannot tell a bot from a person.** No on-chain signal separates an arbitrage bot
  from someone who happened to sell into a stale quote. The surcharge is a price on
  consuming a stale quote, not a penalty on intent.
- **It is blind below 65 ticks**, and on a busy pool most dislocation value lives there.
- **Gap masking pays.** Pushing the reference pool below threshold breaks even at
  **$18k–$40k** of arbitrage notional — inside ordinary trade sizes. Measured, published,
  not fixed. The graduated multiplier does not deter it, because a successful mask means
  no gap opens and there is nothing to multiply.
- **The threshold does not cover the reference's worst case.** 65 ticks against a
  measured sample max of 228.65 bps, on ~0.19% of blocks. Bounded by the surcharge cap,
  not eliminated.
- **Partial closes are overcharged**, since the rate is set from the widest the gap
  reached. Bounded by the cap.
- **All measurement is ETH/USDC on mainnet.** One pair, one chain, three windows.

The full list, with the measurement behind each, is in
[APPENDIX.md](./APPENDIX.md#12-limitations).

---

## Running it

```bash
git clone https://github.com/mansi0xc/backdraft && cd backdraft
forge build

# 228 tests, no network needed
forge test --no-match-path "test/fork/*"

# 9 more against the live mainnet v3 pools the hook names
cp .env.example .env        # add MAINNET_RPC_URL
forge test --match-path "test/fork/*" -vv

# gas, measured against a hookless control pool
forge test --match-contract GasTableTest -vv
```

Dependencies are vendored under `lib/`, so there is no `forge install` step.

**237 tests across 27 suites, and every one of them asserts.** The gas table and the
parameter sweep print their tables and then check them — gas against per-path ceilings,
the sweep against the monotonicity its parameters are supposed to have. The solvency
invariant runs 128 sequences of depth 80 with `fail_on_revert`, which is what it took to
reach the sweep-then-late-claim ordering that surfaced a real payout bug. The fork tests
recompute the reference reader's output from raw `slot0` and `observe` calls and assert
equality, so a wrong pool or a misparsed tuple fails there rather than in production.

There is a frontend under [`ui/`](./ui) with an offline replay of a gap opening,
accruing a ledger, and settling — both regimes, side by side.

---

## Partner Integrations

None. Backdraft integrates no partner technology.

---

<div align="center">
<sub>

**[APPENDIX.md](./APPENDIX.md)** — reference price selection, measured
&nbsp;·&nbsp;
**[ARCHITECTURE.md](./ARCHITECTURE.md)** — contract internals
&nbsp;·&nbsp;
**[python scripts](https://github.com/mansi0xc/backdraft-python-scripts)** — every number above

</sub>
</div>