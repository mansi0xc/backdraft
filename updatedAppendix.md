# §10.1 — Truncated reference, measured across three windows

Source: `truncation_capture.py` against `data/swaps_v3_*` for three ETH/USDC windows.
Gaps are measured **per target-pool swap**, reconstructing what `beforeSwap` would see
(pre-swap pool tick vs the reference at that exact log position), not from per-block
series — block-level forward-fill hides every dislocation that opens and closes inside
a block, which is most of them.

## Windows

| # | blocks | regime | ref swaps | honest p99 \|Δref\|/block | B used |
|---|---|---|---|---|---|
| A | 25821306–25828484 | volatile | 46,344 | 16 | 16 |
| B | 25527155–25534325 | calm | 18,066 | 13 | 13 |
| C | 25598870–25606053 | volatile | 14,076 | 10 | 10 |

`B` is the p99 of honest per-block reference movement, derived the same way §7 derived
the 65-tick gap threshold. It is **regime-dependent**: 16 / 13 / 10 across the three
windows. A hardcoded on-chain bound must be set for the worst regime and is therefore
looser than optimal in calm markets; an adaptive bound is a new manipulation surface
(push volatility, widen the bound). This is unresolved.

## Headline: episodes are mostly the reference, not the pool

Every hook-visible gap is classified by who closed it. **Real** = the target pool
converged to the reference (genuine staleness, the mechanism working). **Glitch** = the
reference reverted to the target (the reference was wrong; a hook trusting it would
have surcharged an innocent swap).

| window | pool | episodes | real | glitch |
|---|---|---|---|---|
| A | v3_005 | 10 | 1 | 9 |
| B | v3_005 | 12 | 1 | 11 |
| C | v3_005 | 10 | 0 | 10 |
| A/B/C | v3_030 | 0 / 0 / 1 | 0 | 1 |
| A/B/C | v3_100 | 1 each | 1 each | 0 |
| **total** | | **36** | **5** | **31** |

**30 of 32 episodes on the deep pool were the reference misbehaving, not the pool going
stale.** The largest was a 722-tick excursion in window A: the 0.01% pool pushed and
arbitraged back within blocks while the governed pool never moved.

## Glitch rejection — replicated, with a monotone decay curve

Share of glitch peak-gap value the truncated reference refused to see. Higher is better;
the raw reference is 0% by construction, because it sees every glitch in full.

| B (ticks/block) | window A | window B | window C |
|---|---|---|---|
| 5 | 100.0% | 100.0% | 100.0% |
| 10 | 100.0% | 100.0% | **94.6%** |
| 13 | — | **97.2%** | 89.0%* |
| 16 | **100.0%** | 96.5%* | 86.0%* |
| 20 | 96.8% | 95.8% | 83.0% |
| 30 | 95.1% | 90.7% | 72.5% |
| 50 | 74.6% | 78.5% | 58.0% |
| 100 | 46.4% | 38.5% | 35.5% |
| ∞ (raw) | **0.0%** | **0.0%** | **0.0%** |

Bold = that window's derived B. \* = interpolated, not in the sweep grid.

Three windows, ~30 glitch episodes, monotone decay in every column, landing on exactly
0% for the raw reference every time. This is the result that replicated.

## Real capture — survives, but under-powered

| window | pool | real episodes | real value captured at derived B |
|---|---|---|---|
| A | v3_005 | 1 | 100.0% |
| B | v3_005 | 1 | 100.0% |
| C | v3_005 | 0 | — |
| A/B/C | v3_100 | 1 each | 100.0% each |

**n = 2 independent real episodes on the deep pool.** One cleared the 65-tick threshold
by a single tick. The three v3_100 episodes are the same chronic staleness measured in
three windows, not three independent observations. These percentages must not be quoted
without their n, and "100% of real value captured" is a hint, not a finding.

## Phantom cost — non-monotone in B

Swaps entering with a truncated gap open while no raw dislocation existed: mischarge
exposure created *by* the bound.

| B | window A | window B | window C |
|---|---|---|---|
| 5 | 0 | 45 | 0 |
| 10 | 0 | 0 | 2 |
| 20 | 0 | 0 | 8 |
| 30 | 0 | 0 | 9 |
| 50 | 0 | 0 | 11 |
| 100 | 0 | 0 | 8 |
| raw | 0 | 0 | 0 |

Window B peaks at the low end, window C in the middle, window A never phantoms at all.
An earlier reading of window B alone suggested B has a hard floor; window C refutes it.
The mechanism: at moderate B the reference partially follows a glitch spike and is still
crawling back after raw has reverted, so it lags in both directions. At very low B it
never follows far enough to cross threshold; at raw it tracks perfectly both ways.
**Phantom cost is not monotone in B and its shape is regime-dependent.**

## Where the mechanism does and does not fire

The mid-flow pool (v3_030) produced **zero** above-threshold dislocations in two of
three windows, including a volatile one, and one glitch in the third. At a 65-tick
threshold the capture mechanism never fires on that flow regime at all. Gap capture has
material work to do only where flow is thin enough for staleness to persist.

## Limitations

- **One token pair.** ETH/USDC only. A second pair is the outstanding gap.
- **Stand-in pools, not Backdraft pools.** v3_100's near-dead flow makes gaps large and
  slow (optimistic for capture); v3_005 hugs the reference (pessimistic).
- **The classifier discriminates reference glitches, not all manipulation.** An attacker
  who pushes the *governed* pool and lets arbitrage revert it resolves in the "real"
  direction by construction.
- **Slow reference drift is not filtered.** Window C's single v3_030 glitch showed 0.0%
  rejection at every B including 5. A per-block bound cannot distinguish a slow
  reference drift from genuine price movement. Truncation rejects fast glitches only.
- **Stand-in correction speed embeds vanilla economics.** A live surcharge raises the arb
  break-even and slows correction, which helps a crawling reference — so measured capture
  is a mild lower bound in that one respect.
- **Peak-gap weighting** prices surcharge per unit notional; per-episode closing notional
  is available in the CSVs and is not yet used.
