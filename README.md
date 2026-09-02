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

189 tests across 23 suites. Everything except the fork suite runs without an RPC.

```bash
# Everything that needs no network — 187 tests
forge test --no-match-path "test/fork/*"

# Reference reader against live mainnet v3 pools — 2 tests
forge test --match-path "test/fork/*" --fork-url $MAINNET_RPC_URL

# Gas table
forge test --match-contract GasTableTest -vv
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
  security/      RouterAuth (identity forwarding), ClaimAuth
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

Not in this repo: the Python benchmark pipeline (`refbench/`) that produced the numbers
below, and the raw swap CSVs it reads.

---

## Reference Price

The reference is the **v3 0.01% ETH/USDC spot tick** — the most frequently corrected
source, not the deepest. A weighted blend of several pools adds no accuracy, because a
weighted median just returns whichever source holds more than half the weight.

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

Gap threshold is 65 ticks, from a measured p100 reference error of ~58 bps across calm
and volatile regimes.

---

## Limitations

- **Identity comes from `hookData`, and allowlisted routers forward it unverified.**
  Attribution resolves to the address named in `hookData` when the caller is an
  allowlisted router, and falls back to the router otherwise. `tx.origin` is no longer
  used anywhere. Routers do not attest that the named address is the caller.
- **Blind below 65 ticks by construction.** Dislocations smaller than the threshold are
  never captured. The dollar-weighted share of dislocation value in that blind spot is
  measured, not assumed.
- **Partial closes are overcharged.** The rate is set from `maxAbsGap` for the gap's
  whole life, so a swap closing a small residual pays the peak rate. Bounded by
  `surchargeCapBps`. Charging on ticks actually closed by each swap is the fix and is
  not implemented.
- **Gap freezing and gap masking are the same attack.** No single divergence tolerance
  closes both. Graduated pricing bounds the damage rather than removing it; a truncated
  reference (bounding per-block reference movement) is measured in `updatedAppendix.md`
  and is documented, not implemented.
- **LP eligibility is snapshot-based.** Claims read the position's current liquidity and
  `addBlock`, not their values at gap open. Growth accumulators are the correct
  primitive.
- **One token pair.** All measurement is ETH/USDC.

---

## Measurement

`updatedAppendix.md` — truncated-reference study across three mainnet windows: glitch
rejection, real capture, and phantom cost, with sample sizes stated.

`CHANGES.md` — the bug-fix record: nine classes of defect found and fixed across the
build, each with the test that pins it.
