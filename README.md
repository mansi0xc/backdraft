# Backdraft

A Uniswap v4 hook that prices the mispricing a swap leaves behind, and returns the
captured value to the traders who created it and the LPs who funded it.

UHI10 · HK-UHI10-1088 · Mansi & Roshan

---

## What it does

When the pool's tick drifts more than `gapThresholdTicks` from an external reference,
Backdraft opens a **gap** and records who opened it. Swaps that close the gap pay a
surcharge on top of the pool fee; the surcharge is escrowed and split between:

- the traders whose swaps opened the gap (they absorbed the price impact), and
- the LPs who were in range and had held their position since before the gap opened.

When the ledger is empty at settlement — the price moved externally and no swap in this
pool caused the dislocation — 100% routes to LPs as LVR compensation. Endogenous and
exogenous cases run through the same code path with no special-casing.

Gap-closing swaps can additionally be given a **discounted LP fee** (`narrowingFee`) via
v4's dynamic-fee override, so closing a gap is cheaper on the fee and more expensive on
the surcharge. Widening swaps pay `baseFee`.

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Foundry | latest stable | `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| Git | any | system |

Dependencies (`v4-core`, `v4-periphery`, `openzeppelin-contracts`, `forge-std`) are
vendored under `lib/` and committed, so no `forge install` step is required.

---

## Setup

```bash
git clone https://github.com/mansi0xc/backdraft
cd backdraft
forge build

# Only needed for the fork tests and deployment
cp .env.example .env
```

`.env` needs:
```
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
ETHERSCAN_API_KEY=YOUR_KEY
```

---

## Running Tests

217 tests across 26 suites. Everything except the fork suite runs without an RPC.
The two fork tests and the eight sweep/gas-table tests print measurements and have no
assertions; the other 202 do.

```bash
# Everything that needs no network — 215 tests
forge test --no-match-path "test/fork/*"

# Reference reader against live mainnet v3 pools — 2 tests
forge test --match-path "test/fork/*" --fork-url $MAINNET_RPC_URL

# Gas table
forge test --match-contract GasTableTest -vv

# Static analysis
forge build --build-info && slither . --ignore-compile --filter-paths "lib/|test/|script/"
```

---

## Repository Layout

```
src/
  BackdraftHook.sol              # beforeSwap, afterSwap, liquidity tracking, settlement, claims
  interfaces/
    IReferencePrice.sol          # (refTick, ok, divTicks)
    IUniswapV3PoolMinimal.sol    # slot0, observe, liquidity
  references/
    SplitV3Reference.sol         # ships: v3 0.01% spot, divergence measured against v3 0.05%
    OwnPoolEmaReference.sol      # broken baseline, kept for comparison — see below
  libraries/
    GapMath.sol                  # gap direction and abs helpers
    SurchargeMath.sol            # surcharge = notional × min(rate × gap, cap)
    DivergenceMath.sol           # divergence → surcharge multiplier, and escrow clamping
    EligibilityLib.sol           # LP age filter and range check

test/
  unit/          BackdraftHook, GapMath, SurchargeMath, SurchargePrecision, Eligibility
  reference/     ReferenceGuard, GraduatedFee
  attribution/   who gets credited for opening a gap
  exogenous/     external price moves with an empty ledger
  exactout/      exact-output swaps
  splitting/     splitting a close across many swaps must not discount it
  liquidity/     LpEligibility, PayoutCap
  lifecycle/     expiry, sign flip, auto-settle
  security/      RouterAuth (identity forwarding), ClaimAuth, Ownership,
                 ReviewRegressions (external review 2026-09-03, six findings)
  fees/          FeeFlip (dynamic-fee override)
  invariant/     Solvency — hook balance ≥ outstanding obligations
  integration/   EndToEnd
  sweep/         ParamSweep, gas table
  fork/          Replay — reference reader against live mainnet pools

script/
  DeployHook.s.sol               # salt mining + per-chain config
```

`OwnPoolEmaReference.sol` is retained deliberately: an EMA of the pool's own price
cannot detect that pool's own staleness. It is the design we started with, and it is
kept as the negative control.

The measurement pipeline that produced every number below lives in a companion repo,
with the raw swap CSVs and generated tables committed:
**https://github.com/mansi0xc/backdraft-python-scripts**

---

## Reference Price

The reference is the **v3 0.01% ETH/USDC spot tick** — the most frequently corrected
source, not the deepest. A weighted blend of several pools adds no accuracy, because a
weighted median just returns whichever source holds more than half the weight. Both
claims are measured, not asserted — see [Measurement](#measurement).

| Pool | Role | Address |
|---|---|---|
| v3 0.01% | reference (freshest) | `0xE0554a476A092703abdB3Ef35c80e0D76d32939F` |
| v3 0.05% | divergence signal (deepest, hardest to push) | `0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640` |

### Divergence is priced, not switched on

`getRefTick` returns `divTicks` — the larger of `|deepSpot − deepTWAP|` and
`|fastSpot − deepSpot|`. Below `guardMaxDevTicks` (50) the surcharge multiplier is
1.00×. Above it the multiplier rises linearly at `divSlopeBps` per tick, up to
`maxDivMultBps`.

This replaced a boolean freeze on the same signal. A freeze is an off-switch anyone can
reach: pushing the thin fast pool one tick past the tolerance costs roughly $21 and
stops all capture on gaps of any size, and no setting of that tolerance closes both the
freeze route and the masking route — tightening it makes the freeze cheaper, loosening
it widens the mask. Pricing the divergence makes manipulation progressively expensive
instead of progressively effective.

`freezeMaxDevTicks` remains as an absurdity backstop (recommended 5× the guard) for
references that are not merely pushed but nonsensical. Setting it to 0 disables freezing
on divergence entirely. The hook still returns inaction on a hard read failure — pool
unconfigured, or `observe()` unavailable.

### Measured fork results

| Metric | Value |
|---|---|
| fast tick | 198094 |
| deep tick | 198092 |
| fast−deep | 2 ticks |
| deep spot−TWAP | 21 ticks |
| `getRefTick` gas | 74,307 |
| `observe()` cardinality | 723 slots — sufficient |

`observe()` accounts for ~58k of the 74k. The read is currently unconditional on every
swap; a two-stage read (cheap `slot0` first, full TWAP only when a gap is indicated) is
the obvious optimisation and is **not** implemented.

Gap threshold is **65 ticks**. It was sized against a measured p100 reference error of
~58 bps — but that figure came from a reference design that withholds its price on the
worst blocks, and the shipped path does not. Measured on the shipped path, p100 is
228.65 bps. The threshold covers p95 with wide margin and the tail with none. See
[Measurement](#the-shipped-path-measured-and-what-it-says-about-the-threshold).

---

## Limitations

- **Identity comes from `hookData`, and allowlisted routers forward it unverified.**
  Attribution resolves to the address named in `hookData` when the caller is an
  allowlisted router, and falls back to the router otherwise. `tx.origin` is no longer
  used anywhere. Routers do not attest that the named address is the caller.
- **Blind below 65 ticks by construction.** On a thin stand-in pool 0.43% of
  dislocation value sits in that blind spot; on a busy one, 61%. Measured — see
  Measurement.
- **Partial closes are overcharged.** The rate is set from `maxAbsGap` for the gap's
  whole life, so a swap closing a small residual pays the peak rate. Bounded by
  `surchargeCapBps`. Charging on ticks actually closed by each swap is the fix and is
  not implemented.
- **Gap masking costs $22k–$54k of arbitrage notional and therefore pays.** Pushing the
  reference pool below threshold is not deterred by the graduated multiplier, because a
  successful mask means no gap opens and there is nothing to multiply. Measured, not
  fixed. See Measurement.
- **Gap freezing and gap masking are the same attack.** No single divergence tolerance
  closes both, and pricing divergence rather than freezing on it made masking cheaper
  for large gaps. A truncated reference (bounding per-block reference movement) is
  measured in `updatedAppendix.md` and is documented, not implemented.
- **LP eligibility is snapshot-based.** Claims read the position's current liquidity and
  `addBlock`, not their values at gap open. Growth accumulators are the correct
  primitive.
- **The gap threshold does not cover the reference's worst case.** 65 ticks against a
  measured p100 of 228.65 bps on the shipped path, in ~0.19% of blocks. Bounded by the
  graduated multiplier and the surcharge cap, not eliminated. See Measurement.
- **The fee discount is bounded by the surcharge on the same swap.** Below ~500
  ticks the discount exactly rebates the surcharge, so a closer pays what a vanilla
  pool would charge and the forgone LP fee reappears in escrow, where the ledger
  splits it. Above that the full `narrowingFee` applies. Closing is never cheaper than
  widening (fuzzed across 70–4000 ticks in `ReviewRegressions.t.sol`).
- **Swept remainders wait for a next gap.** `sweepUnclaimed` no longer donates to
  the pool (which paid whatever liquidity was in range at that instant, JIT included);
  the remainder is carried into the LP pot of the next gap that escrows in the same
  currency, whose claimants are age-filtered. If no such gap ever opens the carry sits
  in the hook indefinitely. There is still no treasury and no owner withdrawal.
- **Reference error is not bounded by the multiplier.** See Measurement. On the ~0.19%
  of blocks where the reference itself is more than 65 ticks wrong, a gap opens that
  should not, and the divergence multiplier raises the charge on it.
- **Position ownership is not tracked across NFT transfer.** Positions are keyed by the
  address the router names at add time. If a PositionManager NFT changes hands, the
  seller keeps the claim.
- **One token pair.** All measurement is ETH/USDC.

---

## Measurement

Every design parameter here came from a measurement, and the measurements are
reproducible: **https://github.com/mansi0xc/backdraft-python-scripts**
(`selftest.py` runs offline; `fetch.py` + `analyze.py` regenerate the tables from an
archive RPC; raw CSVs and generated outputs are committed).

Ground truth is Binance ETH/USDC across three mainnet windows, spanning daily ranges of
3.24%, 6.58% and 21.10%.

### Which source, and why not a blend

Mean absolute error against Binance, per reference source and per combination
(window 25785425–25799780, 14,356 blocks, 1-second ground truth):

| sources | mean err (bps) | p95 | liquidity share | min weight to corrupt |
|---|---|---|---|---|
| `v3_001` | **3.48** | 11.25 | 0.100 | 0.05 |
| `v3_005` | 4.18 | 9.88 | 0.781 | 0.39 |
| `v3_030` | 13.82 | 29.21 | 0.117 | 0.06 |
| `v3_100` | 50.90 | 90.61 | 0.002 | 0.001 |
| `v3_001+v3_005` | 4.18 | 9.88 | 0.881 | 0.44 |
| `v3_005+v3_030` | 4.18 | 9.88 | 0.898 | 0.45 |
| all four | 4.18 | 9.88 | 1.000 | 0.50 |

Two results, both negative, both load-bearing:

**Most-traded beats deepest.** The 0.01% pool is the most accurate single source despite
holding 10% of the liquidity. Freshness, not depth, is what a reference needs.

**Liquidity-weighted aggregation buys nothing.** Every combination containing `v3_005`
returns *identical* error — 4.18 / 9.88, to three decimals. A weighted median returns
whichever source holds more than half the weight, so once the 0.05% pool is in the set
the blend is that pool. The `min weight to corrupt` column is the price of that
accuracy: the single best source is also the cheapest to push (0.05 vs 0.39). That
tradeoff is why divergence is priced rather than ignored.

### Reference error and guard cost

| Method | mean (bps) | p95 | max | lag (blocks) | coverage |
|---|---|---|---|---|---|
| `shipped_fast_spot_frozen` | 2.69 | 8.55 | 70.97 | 19 | 89.9% |
| **`shipped_fast_spot_raw`** (ships) | **3.48** | **11.25** | **228.65** | **0** | **100%** |
| `composite_median_guarded` | 3.50 | 8.15 | 57.97 | 19 | 89.9% |
| `spot_v3_005` | 4.18 | 9.88 | 228.65 | 0 | 100% |
| `twap_1800s_v3_005` | 25.18 | 76.94 | 639.0 | 7 | 100% |
| `own_pool_ema` | 58.23 | 115.52 | 564.01 | 14 | 100% |

Coverage below 100% is not a defect of measurement — it is a design that refuses to
answer. The two 89.9% rows freeze on divergence; the shipped path never does.

`own_pool_ema` is 16x worse than the reference that ships. A pool cannot detect its own
staleness from its own history, and this is the number that says so.

### The shipped path, measured, and what it says about the threshold

The rows above score candidate designs. `shipped_fast_spot_raw` scores what the contract
actually does: `v3_001` spot, divergence priced rather than frozen, reference never
withheld.

Windows are described by the measured daily range of the ground-truth series rather
than by an adjective, because the adjectives were wrong in an earlier draft and the
number cannot be:

| window | dates | ETH daily range | mean | p95 | **max** | blocks |
|---|---|---|---|---|---|---|
| 25785425–25799780 | Aug 19–21 (48h, 1s truth) | 21.10% | 3.48 | 11.25 | **228.65** | 14,356 |
| 25527155–25534325 | Jul 14 | 6.58% | 4.15 | 13.13 | **112.14** | 7,166 |
| 25598870–25606053 | Jul 24 | 3.24% | 2.31 | 6.77 | **42.05** | 7,179 |

Worst-case reference error tracks realised volatility closely across the three, which is
what you would expect and is worth stating: the tail is a volatility phenomenon, so a
threshold sized on a quiet window will be wrong on a loud one.

**The 65-tick gap threshold does not cover the worst case of the shipped
configuration.** It was sized against 57.97 bps — the max of
`composite_median_guarded`, a design that withholds the reference on divergence and
therefore never reports its worst blocks. The shipped path never withholds, so its tail
is intact, and in the volatile window it reaches 228.65 bps: 3.5x the threshold.

How often that matters, same window:

| reference error exceeds | share of blocks |
|---|---|
| 65 ticks (the threshold) | 0.188% (27 of 14,356) |
| 100 ticks | 0.077% |
| 150 ticks | 0.042% |
| 200 ticks | 0.007% (1 block) |

So roughly two blocks in a thousand can open a gap that is an artifact of reference
error rather than a real dislocation, and on the worst of them the artifact is large
enough to charge near the cap. Nothing in the shipped design reduces that mischarge.
The divergence multiplier can only *raise* a surcharge, and because divergence and
reference error peak together, on exactly those blocks it makes the mischarge larger,
not smaller. The multiplier is a deterrent against pushing the reference; it is not a
bound on the reference being wrong. Stated as a limitation below.

This is stated rather than fixed. Raising the threshold to cover p100 would blind the
hook to most real dislocations; the truncated reference in `updatedAppendix.md` is the
design that addresses the tail directly, and it is not implemented.

### Divergence, measured

`divTicks` drives the surcharge multiplier and had never been characterised:

| window | ETH daily range | p50 | p95 | p99 | max | blocks over the 50-tick tolerance |
|---|---|---|---|---|---|---|
| Aug 19–21 | 21.10% | 13.0 | 78.2 | 247.0 | 642.3 | 10.06% |
| Jul 14 | 6.58% | 9.2 | 40.7 | 125.6 | 178.9 | 3.89% |
| Jul 24 | 3.24% | 6.8 | 32.0 | 62.3 | 98.5 | 1.67% |

The multiplier engages on 1.7%–10% of blocks, monotone in realised volatility. Under the
old boolean guard those were exactly the blocks where the hook went dark — most often
precisely when dislocations are largest. That is the downtime the graduated curve
removed, and it is the strongest argument for pricing divergence rather than freezing
on it.

### Regime coverage, stated honestly

Three windows spanning 6.58%, 3.24% and 21.10% daily range. That is one violent day and
two ordinary ones; there is no genuinely calm window in the set. Claims of the form
"holds across calm and volatile regimes" are not supported by this data and are not
made. A quiet-market window is an outstanding gap, alongside the second token pair.

### Where the value actually is

Block shares do not answer the question that matters, because volatility clusters: the
blocks the guard would freeze are not a random 10% of blocks. Every swap in a target
pool is bucketed by what `beforeSwap` would have seen — pre-swap pool tick against the
0.01% reference at that log position — and weighted by `|gap| x swap notional`, which is
the surcharge base.

Volatile window, three stand-in target pools:

| target pool | swaps | blind (\|gap\| ≤ 65) | capturable at 1.00x | in divergent blocks |
|---|---|---|---|---|
| v3 1.00% (thin) | 114 | 0.43% | 8.83% | **90.73%** |
| v3 0.30% (mid) | 1,154 | 63.30% | 0.00% | **36.70%** |
| v3 0.05% (busy) | 14,868 | 60.92% | 0.45% | **38.63%** |

Two findings, and the second is the reason the design changed.

**The blind spot is a function of flow, not of the threshold.** On a thin pool almost
all dislocation value clears 65 ticks; on a busy pool most of it never does. Backdraft
is economically meaningful on thin pools of major pairs — a new v4 pool bootstrapping
against a deep v3 incumbent — and close to irrelevant on a pool that is already the
price-setter. That is a positioning statement, not a defect, but it should be said out
loud rather than discovered by a judge.

**A boolean guard would have switched the hook off on 37%–91% of the value it exists to
capture.** The blocks where spot and TWAP disagree are exactly the blocks where a fast
exogenous move is happening. Under the old freeze, that value was not merely uncaptured,
it was invisible. Pricing divergence instead of freezing on it moves the whole of that
column back into scope, at a raised multiplier:

| target pool | capturable, boolean guard | capturable, shipped |
|---|---|---|
| v3 1.00% | 8.83% | **99.57%** |
| v3 0.30% | 0.00% | **36.70%** |
| v3 0.05% | 0.45% | **39.08%** |

This is the strongest single argument in the project for pricing divergence, and it was
computed after the change rather than before it. Appendix §A2 predicted the direction
and declined to guess the size; the size is an order of magnitude.

Caveats that belong with the number: `n = 114` swaps on the thin pool, so its column is
indicative and not a finding; the TWAP is a 150-block rolling mean of deep-pool swaps
rather than a v3 `observe()` result; and these are stand-in pools, not Backdraft pools.
Script: `bucket_value.py`, output in `out/bucket_value_25785425_25799780.txt`.

### Truncated reference

`updatedAppendix.md` — a per-swap study across three mainnet windows of bounding how far
the reference may move per block. Glitch rejection is monotone in the bound and lands at
0% for the raw reference in all three windows; real capture holds but rests on n = 2
independent episodes; phantom cost is non-monotone and regime-dependent. Measured, not
implemented.

### Manipulation cost

The attack this hook is most exposed to: push the thin 0.01% reference pool toward the
v4 price until the apparent gap falls below threshold. No gap opens, the arbitrageur
closes the whole dislocation surcharge-free, then unwinds. Measured against 46,344 swap
events at p10 in-range liquidity — the attacker's best moment — with gas at 10 gwei:

| gap (ticks) | push needed | push notional | attack cost | avoided | break-even arb notional |
|---|---|---|---|---|---|
| 66 | 2 | $2,836 | $7 | 3.30 bps | **$22,203** |
| 100 | 36 | $51,099 | $17 | 5.00 bps | **$33,959** |
| 200 | 136 | $193,526 | $45 | 10.00 bps | **$45,465** |
| 400 | 336 | $480,524 | $103 | 20.00 bps | **$51,432** |
| 600 | 536 | $770,407 | $161 | 30.00 bps | **$53,614** |

**$22k–$54k of arbitrage notional, at every gap size.** That is inside ordinary trade
size on this pair, so the attack pays. Stating it is the point: the mechanism is
defensible at the sizes it will actually see, and it is not defended against a
determined searcher on a thin reference pool.

Pricing divergence made this attack *cheaper*, and that trade should be visible rather
than buried. Under the old boolean guard, a 50-tick push froze the reference, which
capped the push at 49 ticks and left break-even flat at $84,386 for every gap above 113.
The shipped design has no cliff, so the push is limited only by cost — and because a
full mask means no gap opens, the graduated multiplier has nothing to multiply. The
deterrent does not bind on the attack it most needs to deter.

| gap | break-even, old boolean guard | break-even, shipped |
|---|---|---|
| 114 | $84,386 | $36,770 |
| 400 | $84,386 | $51,432 |

Removing the freeze closed the gap-freezing attack and widened the gap-masking one.
They are the same attack from opposite sides. The truncated reference in
`updatedAppendix.md` is the design that bounds both — a per-block movement cap limits how
far any push moves the hook's view, however much the attacker spends — and it is measured
and not implemented.

Full table and unmodelled assumptions: `out/manipulation_cost_25785425_25799780.md` in
the measurement repo.

`CHANGES.md` — the build log. The bug-fix record is the test suite itself: every
patch directory (`exactout/`, `splitting/`, `lifecycle/`, `security/`, …) opens with
the defect it pins and the measurement that found it.

### External review, 2026-09-03

Seven findings against the pre-review build, each pinned in
`test/security/ReviewRegressions.t.sol`:

| # | finding | status |
|---|---|---|
| R1 | claim after sweep paid from other gaps' escrow | **fixed** — sweep marks pots exhausted; claims refuse swept gaps |
| R2 | sweep donates to JIT liquidity | **fixed** — remainder carried into the next same-currency gap's LP pot |
| R3 | swap crossing the reference opened an endogenous gap with an empty ledger | **fixed** — credited for the exit-side gap it created |
| R4 | fee flip inverts "closing costs more" at gaps under ~500 ticks | **fixed** — discount bounded by the surcharge on the same swap |
| R5 | old-LP withdrawal in the lookback masked JIT adds in the denominator | **fixed** — decrement only for positions added inside the window |
| R6 | `setPoolCfg` accepted `traderShareBps > 100%`, bricking every closing swap | **fixed** — bounded |
| R7 | reference crossing the pool with no swap made every swap toward the new reference revert until expiry | **fixed** — beforeSwap closes a gap whose sign no longer matches the market. Found by the rewired invariant, not by reading. |

The solvency invariant was rewritten in the same pass: it now sums
`escrowed − lpPaid − traderPaid` over every non-swept gap (it previously counted only
gaps not yet settled, which — because closing auto-settles — was almost nothing),
includes `sweepUnclaimed` and `moveOracle` in the handler, runs at depth 80 with
`fail_on_revert = true`, and counts pending carry as an obligation. At depth 15 it
could not reach sweep → late claim and did not catch R1; at 80 it does. Wiring
`moveOracle` surfaced R7 on the first run.
