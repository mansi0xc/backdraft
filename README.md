# Backdraft

A Uniswap v4 hook that prices the mispricing a swap leaves behind, and returns the captured value to the traders who created it and the LPs who funded it.

UHI10 · HK-UHI10-1088 · Mansi & Roshan

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Foundry | latest stable | `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| Git | any | system |
| Python 3.10+ | for refbench only | system |

---

## Setup

```bash
git clone <repo-url>
cd uhi10

# Install Solidity dependencies
forge install

# Copy env template and fill in your RPC URL and Etherscan key
cp .env.example .env
```

`.env` needs:
```
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
ETHERSCAN_API_KEY=YOUR_KEY
```

---

## Running Tests

### Unit tests (no RPC needed)
```bash
forge test --match-path "test/unit/*" -v
```

### Fork tests (requires `MAINNET_RPC_URL`)
```bash
forge test --match-contract ReplayForkTest --fork-url $MAINNET_RPC_URL -vvvv
```

### All tests
```bash
forge test --fork-url $MAINNET_RPC_URL -v
```

### Gas snapshot
```bash
forge snapshot --fork-url $MAINNET_RPC_URL
```

---

## Repository Layout

```
src/
  BackdraftHook.sol              # Main hook — beforeSwap, afterSwap, settlement, claims
  interfaces/
    IReferencePrice.sol          # Interface for the external price source
    IUniswapV3PoolMinimal.sol    # Minimal v3 pool interface (slot0, observe, liquidity)
  references/
    SplitV3Reference.sol         # Ships: fast v3 0.01% spot guarded by deep v3 0.05% TWAP
    OwnPoolEmaReference.sol      # Broken baseline — included for accuracy comparison only
  libraries/
    GapMath.sol                  # Gap direction and abs helpers
    SurchargeMath.sol            # Surcharge = notional × min(rate × gap, cap)
    EligibilityLib.sol           # LP age filter and range check

test/
  unit/
    GapMath.t.sol
    SurchargeMath.t.sol
    Eligibility.t.sol
  integration/
    EndToEnd.t.sol               # Full Rohan → Vik → settle → claim scenario (Day 4)
  invariant/
    Solvency.t.sol               # Σ claimable ≤ contract balance (Day 5)
  fork/
    Replay.t.sol                 # Reference reader against live mainnet pools (Day 1 ✓)

script/
  DeployHook.s.sol               # Deploy — requires HookMiner salt for address bit pattern

refbench/                        # Python benchmark (see below)
  data/                          # Raw swap CSVs — already fetched, not committed
```

---

## Reference Price — Measured, Not Assumed

The reference price is the **v3 0.01% ETH/USDC spot tick** — the most frequently corrected source across four measurement conditions (calm, volatile, USDT-stressed, 1s truth).

| Pool | Role | Address |
|---|---|---|
| v3 0.01% | Reference (freshest) | `0xE0554a476A092703abdB3Ef35c80e0D76d32939F` |
| v3 0.05% | Guard (deepest, hardest to push) | `0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640` |

Guard fires (hook freezes — no surcharge, no ledger write) when either:
- `|deepSpot − deepTWAP| > 50 ticks` — deep pool being manipulated
- `|fastSpot − deepSpot| > 50 ticks` — fast pool being manipulated

**Measured fork results (Day 1):**

| Metric | Value |
|---|---|
| fast tick | 198094 |
| deep tick | 198092 |
| fast-deep diff | 2 ticks (threshold: 50) |
| deep spot-TWAP diff | 21 ticks (threshold: 50) |
| `reference()` gas | **74,307** |
| `observe()` cardinality | 723 slots — sufficient |
| Guard status | PASS (`ok = true`) |

Gas note: `observe()` accounts for ~58k of the 74k total. A two-stage read optimisation (cheap `slot0` first, full TWAP guard only when a gap is indicated) is implemented in `beforeSwap` to avoid paying this on every swap.

Full measurement methodology and four-condition accuracy table: `backdraft_appendix.pdf`.

---

## Dependency Hashes

Pinned at install time — record resolved commits here after `forge install`:

```
v4-core:                 e50237c43811bd9b526eff40f26772152a42daba
v4-periphery:            dce236d4e2057422d0791d9a973a58765eb46f65
openzeppelin-contracts:  cab19933c33c2ad1d4c7a84864a3601dddfd16f3
forge-std:               375fadbbf6c8bbf4c0cbcaf9af58118a4a76d45d
```

---

## Limitations

See `idea.md` §6 for the full list. Key ones for reviewers:

- `tx.origin` attribution works through the Universal Router but breaks for ERC-4337 and batched transactions. Demo uses direct swaps.
- The hook is blind below 65 ticks by construction and freezes ~10% of volatile blocks. The dollar-weighted share of dislocation value that falls in this blind spot is measured and reported as a finding — see §0.5-B1 in `plan.md`.
- Partial-close swaps are slightly overcharged (charged on full gap, not partial close). Bounded by `surchargeCapBps`.

---

## No Partner Integrations
