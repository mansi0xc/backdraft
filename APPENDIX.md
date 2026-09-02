# Backdraft — Technical Appendix

UHI10 · HK-UHI10-1088 · Uniswap v3 ETH/USDC, Ethereum mainnet

This supersedes `Backdraft_Appendix_v2.pdf` and the earlier `updatedAppendix.md`. Both
described a design Backdraft no longer ships: a reference that **freezes** when its two
sources disagree. The shipped hook **prices** that disagreement instead. Sections 6, 7
and A3 of the PDF are superseded below; everything else in it stands.

Reproduce every number: https://github.com/mansi0xc/backdraft-python-scripts

---

## 1. Windows

Described by measured daily range rather than by adjective. An earlier draft labelled
these "calm" and "volatile" and had two of them backwards.

| blocks | dates (UTC) | ETH daily range | net | ground truth |
|---|---|---|---|---|
| 25785425–25799780 | 19–21 Aug 2026 (48 h) | 21.10% | +21.41% | ETHUSDC 1 s |
| 25527155–25534325 | 14 Jul 2026 | 6.58% | +6.56% | ETHUSDC 1 m |
| 25598870–25606053 | 24 Jul 2026 | 3.24% | −0.82% | ETHUSDC 1 m |

There is no genuinely calm window in this set: one violent period and two ordinary days.
Claims of the form "holds across calm and volatile regimes" are not supported and are
not made. A quiet-market window is outstanding, alongside a second token pair.

---

## 2. Source selection (§3–§4 of the PDF, unchanged)

The 0.01% tier is the most accurate single source in all four measurement conditions
while holding 10% of pair liquidity. Every liquidity-weighted combination containing the
0.05% pool returns *exactly* that pool's error to three decimals, because a weighted
median returns whatever holds more than half the weight. Accuracy gained by going
multi-source: 0.000 bps.

| sources | mean err | p95 | liq. share | min_weight |
|---|---|---|---|---|
| v3_001 alone | **3.482** | 11.254 | 0.100 | 0.050 |
| v3_001 + v3_005 | 4.177 | 9.882 | 0.881 | 0.441 |
| all four | 4.177 | 9.882 | 1.000 | 0.500 |

Because the freshest source is not the deepest, weighting by liquidity systematically
selects the staler price. Standard oracle practice weights by depth; on this pair that
is the wrong direction.

---

## 3. A3 resolved: the recommended configuration, measured

PDF §7 flagged that the shipped design — fast-pool spot guarded against the deep pool —
was **inferred from components, not measured**, and §A3 recorded a falsifiable
prediction: *"fast-source mean accuracy (≈3.5 bps) with worst-case suppression
comparable to the measured guard (≈58 bps)."*

It has now been added to `analyze.py` and run. Volatile window, 1-second truth:

| method | mean | p95 | max | lag | coverage |
|---|---|---|---|---|---|
| `shipped_fast_spot_frozen` | 2.69 | 8.55 | **70.97** | 19 | 89.9% |
| `shipped_fast_spot_raw` (ships) | 3.48 | 11.25 | **228.65** | 0 | 100% |
| `composite_median_guarded` (what §7 measured) | 3.50 | 8.15 | 57.97 | 19 | 89.9% |

**The prediction was half right.** Mean accuracy came in better than predicted — 2.69
against ≈3.5. Worst-case suppression came in *worse*: 70.97 against ≈58, a 22% miss.
The inference was optimistic in exactly the direction that mattered for the threshold.

---

## 4. A1 resolved, and the consequence §7 did not anticipate

A1 corrected "p100" to "sample p100". The larger problem is which sample.

`gapThresholdTicks = 65` was set above 57.97 bps — the max of
`composite_median_guarded`. That method has 89.9% coverage: **it withholds its price on
the blocks where it would be most wrong, so its measured maximum is censored by
construction.** The shipped path never withholds. Its p100 is 228.65 bps, 3.5× the
threshold.

Replication:

| window | ETH daily range | shipped max err |
|---|---|---|
| 19–21 Aug | 21.10% | 228.65 |
| 14 Jul | 6.58% | 112.14 |
| 24 Jul | 3.24% | 42.05 |

The tail scales with realised volatility, so a threshold sized on a quiet window is
wrong on a loud one. Frequency, volatile window: 0.188% of blocks exceed 65 ticks of
reference error (27 of 14,356), 0.077% exceed 100, one block exceeds 200.

Roughly two blocks per thousand can open a gap that is an artifact of reference error
rather than a dislocation. The graduated multiplier prices the symptom — divergence and
error peak together — but does not bound the error. Raising the threshold to cover p100
would blind the hook to nearly every real dislocation. The truncated reference (§7
below) is the design that addresses the tail directly, and it is not implemented.

---

## 5. A2 resolved: where the value actually is

A2 promised this and declined to guess the answer. Both promised quantities are computed
here.

Every swap in a target pool is bucketed by what `beforeSwap` would have seen — pre-swap
pool tick against the 0.01% reference at that exact log position — and weighted by
`|gap| × swap notional`, the surcharge base.

Volatile window:

| target pool | swaps | blind (\|gap\| ≤ 65) | capturable at 1.00× | in divergent blocks |
|---|---|---|---|---|
| v3 1.00% (thin) | 114 | 0.43% | 8.83% | **90.73%** |
| v3 0.30% (mid) | 1,154 | 63.30% | 0.00% | **36.70%** |
| v3 0.05% (busy) | 14,868 | 60.92% | 0.45% | **38.63%** |

**The blind spot is a function of flow, not of the threshold.** On a thin pool nearly all
dislocation value clears 65 ticks; on a busy pool most of it never does. Backdraft is
economically meaningful on thin pools of major pairs — a new v4 pool bootstrapping
against a deep v3 incumbent — and close to irrelevant on a pool that is already the
price-setter.

**A boolean guard would have switched the hook off on 37%–91% of the value it exists to
capture.** A2's hostile reading is confirmed, and by a wider margin than it feared. The
blocks where spot and TWAP disagree are the blocks where a fast exogenous move is
happening.

| target pool | capturable, boolean guard | capturable, shipped |
|---|---|---|
| v3 1.00% | 8.83% | **99.57%** |
| v3 0.30% | 0.00% | **36.70%** |
| v3 0.05% | 0.45% | **39.08%** |

Caveats belonging with the number: n = 114 on the thin pool, so its column is indicative,
not a finding; the TWAP is a 150-block rolling mean of deep-pool swaps rather than a v3
`observe()`; these are stand-in pools, not Backdraft pools.

Script: `bucket_value.py`.

---

## 6. Superseding §6 and §7 of the PDF: the guard became a price

PDF §6 recommends freezing on spot-vs-TWAP divergence and reports the trade as "worst-
case error falls 4× for 10% downtime". §7 lists the failure mode as "Freeze — no credit,
no surcharge". **Neither describes the shipped hook.**

`getRefTick` now returns `divTicks` — the larger of `|deepSpot − deepTWAP|` and
`|fastSpot − deepSpot|`. Below `guardMaxDevTicks` (50) the surcharge multiplier is
1.00×; above it the multiplier rises linearly at `divSlopeBps` per tick to
`maxDivMultBps`. `freezeMaxDevTicks` remains as an absurdity backstop and can be set to
zero. The hook still returns inaction on a hard read failure.

Three measurements drove the change:

1. A freeze is an off-switch anyone can reach. Pushing the thin fast pool one tick past
   the tolerance costs about $21 and stops all capture on gaps of any size.
2. §5 above: freezing would have discarded 37%–91% of capturable value.
3. Divergence itself, never previously characterised:

| window | p50 | p95 | p99 | max | blocks over tolerance |
|---|---|---|---|---|---|
| 19–21 Aug (21.10%) | 13.0 | 78.2 | 247.0 | 642.3 | 10.06% |
| 14 Jul (6.58%) | 9.2 | 40.7 | 125.6 | 178.9 | 3.89% |
| 24 Jul (3.24%) | 6.8 | 32.0 | 62.3 | 98.5 | 1.67% |

### What the change cost

Masking became cheaper. The attack: push the reference pool toward the v4 price until
the apparent gap falls below threshold; no gap opens, the arbitrageur closes the whole
dislocation surcharge-free, then unwinds. Measured at p10 in-range liquidity across
46,344 swap events, gas at 10 gwei:

| gap | push | push notional | attack cost | avoided | break-even arb notional |
|---|---|---|---|---|---|
| 66 | 2 | $2,836 | $7 | 3.30 bps | **$22,203** |
| 100 | 36 | $51,099 | $17 | 5.00 bps | **$33,959** |
| 200 | 136 | $193,526 | $45 | 10.00 bps | **$45,465** |
| 400 | 336 | $480,524 | $103 | 20.00 bps | **$51,432** |
| 600 | 536 | $770,407 | $161 | 30.00 bps | **$53,614** |

Under the boolean guard the push was capped at 49 ticks, because 50 tripped the freeze —
which held break-even flat at $84,386 for every gap above 113 and made large
dislocations look defended. There is no cliff now, so the push is limited only by cost.
And because a full mask means no gap opens, **the graduated multiplier has nothing to
multiply: the deterrent does not bind on the attack it most needs to deter.**

| gap | break-even, boolean guard | break-even, shipped |
|---|---|---|
| 114 | $84,386 | $36,770 |
| 400 | $84,386 | $51,432 |

$22k–$54k of arbitrage notional, flat across gap sizes, inside ordinary trade size on
this pair. Gap freezing and gap masking are the same attack from opposite sides, and no
single divergence tolerance closes both. This is the price paid for removing the
off-switch, and on the evidence of §5 it was worth paying.

---

## 7. Truncated reference — measured, not implemented

Bounding how far the reference may move per block to B ticks. Per-swap measurement
across three windows; B is the p99 of honest per-block reference movement and is
regime-dependent (10–16).

Glitch rejection — the share of spurious peak-gap value a truncated reference refuses to
see — is monotone in B and lands at exactly 0% for the raw reference in every window:
100% at B = 5, 95–100% at each window's derived B, 35–46% at B = 100. Real capture holds
at 100% but rests on **n = 2** independent episodes, one of which cleared the 65-tick
threshold by a single tick; this is a hint, not a finding. Phantom cost — swaps entering
with a truncated gap open while no raw dislocation existed — is **not monotone in B** and
its shape is regime-dependent.

A truncated reference is what would bound both §4's error tail and §6's masking attack,
because it caps how far any push moves the hook's view regardless of what the attacker
spends. It is the highest-value unimplemented item in the project.

**Data gap, stated:** an earlier draft reported a third window at blocks
25821306–25828484, including a 722-tick excursion. That window's CSVs are not in the
measurement repo and the result is not reproducible. It is withdrawn rather than quoted.

---

## 8. Prior art (§8 of the PDF, unchanged)

Alexander, Chen, Deng & Fu (2025), *Journal of Futures Markets* 45(8), 1023–1048, report
that v3 prices in 0.05% pools tend to lead v2 and 0.30% pools and that the 0.01% pool is
marginally more efficient than the 0.05%. This work reproduces their ordering
independently, with a different metric on a different pair.

Reading external pools from a hook is not novel: Detox uses Pyth, ArbHook uses Chainlink
CRE, WTH uses a second connected pool, Read-on-L1 uses Scroll's L1SLOAD, arb-hook reads
external V2/V3 pools. Uniswap Labs' own Truncated Oracle hook caps per-block tick
movement.

| | prior work | this work |
|---|---|---|
| source selection | by depth, or whatever feed exists | by measured accuracy against CEX |
| reference vs guard | same source for both | split: fast prices, deep guards |
| divergence handling | freeze or ignore | priced, with the value cost of freezing measured |
| threshold setting | chosen | derived, then shown to be under-sized |
| published error | none found | four conditions, bps against CEX |

---

## 9. Limitations

- **One pair, one chain, three windows.** ETH/USDC on mainnet, no genuinely calm window.
- **The gap threshold does not cover the reference's worst case.** 65 ticks against a
  measured p100 of 228.65 bps on the shipped path, ~0.19% of blocks.
- **Masking pays at $22k–$54k** of arbitrage notional and is not deterred by the
  multiplier.
- **Stand-in pools, not Backdraft pools.** The thin pool's flow makes gaps large and slow
  (optimistic); the busy pool hugs the reference (pessimistic).
- **n = 2 real truncation episodes**, and n = 114 swaps on the thin bucket column.
- **Manipulation figures are analytic**, from the weighted-median breakpoint and a
  constant-`L` push model. No attack was executed against a live pool. Constant `L`
  makes the modelled push an upper bound, i.e. generous to the defence.
- **The margin on the source ordering is small** — 0.19–0.76 bps, near instrument
  precision. Four conditions agree on the sign; the magnitude is not claimed.
- **Block timestamps are interpolated** at 12.04 s/block.
- **LP eligibility is snapshot-based** in the contract; growth accumulators are the
  correct primitive and are not used.
