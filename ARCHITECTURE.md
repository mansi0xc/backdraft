# Backdraft — Architecture

Diagrams are generated from the code in `src/`, not from the design docs. Where the two
disagree, the code wins and the diagram follows the code.

All diagrams are Mermaid `flowchart` or `sequenceDiagram`, both of which import into
Excalidraw via **mermaid-to-excalidraw** (`Excalidraw → Insert → Mermaid`). `stateDiagram`
and `erDiagram` do **not** import cleanly, so the gap lifecycle below is drawn as a
flowchart rather than a state machine on purpose.

---

## 1. The idea, in one picture

The three swaps: the one that creates the dislocation, the one that profits from it, and
the settlement that doesn't exist on an ordinary pool.

```mermaid
flowchart LR
    A["<b>Swap 1 — the fund</b><br/>sells 400 ETH<br/>moves the tick 90 ticks"] --> B{"Pool now<br/>disagrees with<br/>the market"}
    B --> C["<b>Swap 2 — the searcher</b><br/>buys the cheap ETH<br/>sells it on Binance"]
    C --> D["Price is correct again"]

    B -.->|"cost borne by"| E["LPs sold below market"]
    A -.->|"cost borne by"| F["Fund ate the price impact"]
    C -.->|"value captured by"| G["Searcher keeps the spread"]

    D ==>|"<b>Backdraft adds this</b>"| H["<b>Swap 3 — settlement</b><br/>surcharge on the closing swap"]
    H --> I["to the fund<br/><i>traderShareBps</i>"]
    H --> J["to the LPs<br/><i>the remainder</i>"]

    E -.-> J
    F -.-> I

    classDef loss fill:#4a1f1f,stroke:#a33,color:#fff
    classDef gain fill:#1f3a1f,stroke:#3a3,color:#fff
    classDef new fill:#1f2f4a,stroke:#37a,color:#fff
    class E,F loss
    class G gain
    class H,I,J new
```

---

## 2. Component layout

```mermaid
flowchart TB
    subgraph external["External state — read only"]
        V3F["v3 0.01% ETH/USDC<br/><i>reference price</i><br/>most-traded, so freshest"]
        V3D["v3 0.05% ETH/USDC<br/><i>divergence signal</i><br/>deepest, hardest to push"]
    end

    subgraph oracle["SplitV3Reference"]
        GRT["getRefTick(id)<br/>→ (refTick, ok, divTicks)"]
        GRT --- DIVN["divTicks = max(<br/>abs(deepSpot − deepTWAP),<br/>abs(fastSpot − deepSpot))"]
    end

    subgraph hook["BackdraftHook"]
        BS["beforeSwap<br/>detect · price · escrow"]
        AS["afterSwap<br/>attribute · close"]
        LIQ["beforeAddLiquidity<br/>beforeRemoveLiquidity<br/><i>position age + checkpoints</i>"]
        CLAIM["settle · claimTrader<br/>claimLp · sweepUnclaimed"]
    end

    subgraph libs["Libraries"]
        GM["GapMath<br/>direction, abs"]
        SM["SurchargeMath<br/>notional × min(rate×gap, cap)"]
        DM["DivergenceMath<br/>divTicks → multiplier"]
        EL["EligibilityLib<br/>age + range filter"]
    end

    PM["Uniswap v4 PoolManager"]

    V3F --> GRT
    V3D --> GRT
    GRT --> BS
    PM -->|"hook callbacks"| BS
    PM -->|"hook callbacks"| AS
    PM -->|"hook callbacks"| LIQ
    BS --> GM
    BS --> SM
    BS --> DM
    AS --> GM
    CLAIM --> EL
    BS -->|"mint 6909 · BeforeSwapDelta"| PM
    CLAIM -->|"burn · take · donate"| PM
```

---

## 3. `beforeSwap` — detect, price, escrow

Every early return is a real branch in the code. The order matters: direction is decided
on the **pre-swap** gap and cached, before any early return, because a swap that is not
surcharged can still be a legitimate widener.

```mermaid
flowchart TD
    S(["beforeSwap"]) --> PM{"msg.sender<br/>== PoolManager?"}
    PM -->|no| REV(["revert 'not PM'"])
    PM -->|yes| ORACLE["getRefTick(id)"]

    ORACLE --> OK{"ok?"}
    OK -->|"no — unconfigured,<br/>observe() reverted,<br/>or past the backstop"| INVAL["invalidate cache<br/><i>afterSwap must not attribute<br/>using a stale direction</i>"]
    INVAL --> ZERO1(["ZERO_DELTA · no fee override"])

    OK -->|yes| SLOT["read slot0<br/>gapBefore = tick − refTick"]
    SLOT --> CACHE["<b>cache direction</b><br/>wasNarrowing, absGapBefore, refTick<br/><i>before any early return</i>"]

    CACHE --> EXP{"open gap<br/>past expiryBlock?"}
    EXP -->|yes| CLOSE1["_closeGap<br/><i>stop charging the stale peak rate</i>"]
    CLOSE1 --> NOGAP
    EXP -->|no| HASGAP{"gap open?"}

    HASGAP -->|no| NOGAP{"abs(gapBefore) ><br/>gapThresholdTicks?"}
    NOGAP -->|"no"| ZERO2(["ZERO_DELTA"])
    NOGAP -->|"yes — pre-existing,<br/>the market moved<br/>while we sat stale"| OPEN["_openGap<br/><i>empty ledger → exogenous</i>"]

    HASGAP -->|yes| NARROW
    OPEN --> NARROW{"is this swap<br/>narrowing?"}
    NARROW -->|"no — widener"| ZERO3(["ZERO_DELTA<br/><i>credited in afterSwap</i>"])

    NARROW -->|yes| NOTIONAL["notional in the INPUT currency<br/><i>exact-output converted at<br/>the pre-swap price</i>"]
    NOTIONAL --> PRICE["surcharge = notional ×<br/>min(rate × <b>maxAbsGap</b>, cap)<br/><i>peak, not prevailing —<br/>splitting buys no discount</i>"]
    PRICE --> MULT["× DivergenceMath.multiplierBps(divTicks)"]
    MULT --> CUR{"escrow currency<br/>matches the gap's?"}
    CUR -->|no| REV2(["revert EscrowCurrencyMismatch"])
    CUR -->|yes| BOOK["record escrow<br/><i>writes before the external call</i>"]
    BOOK --> MINT["poolManager.mint<br/>ERC-6909 claim"]
    MINT --> RET(["BeforeSwapDelta(surcharge)<br/>+ optional narrowingFee override"])

    classDef exit fill:#2a2a2a,stroke:#888,color:#ddd
    classDef bad fill:#4a1f1f,stroke:#a33,color:#fff
    class ZERO1,ZERO2,ZERO3,RET exit
    class REV,REV2 bad
```

---

## 4. `afterSwap` — attribute and close

```mermaid
flowchart TD
    S(["afterSwap"]) --> V{"cache valid?"}
    V -->|"no — the oracle<br/>was unreadable"| X1(["no attribution"])
    V -->|yes| TICK["read slot0<br/>gapNow = tick − cached refTick"]
    TICK --> CRED["creditable = <b>!wasNarrowing</b><br/><i>you are not paid for<br/>closing what you are charged to close</i>"]
    CRED --> ID["trader = _resolveUser(sender, hookData)<br/><i>allowlisted router forwards identity;<br/>never tx.origin</i>"]

    ID --> HAS{"gap open?"}
    HAS -->|no| NEW{"abs(gapNow) ><br/>threshold?"}
    NEW -->|"no"| X2(["nothing to do"])
    NEW -->|"yes — <b>this swap</b><br/>caused it"| OPEN2["_openGap<br/>+ _credit the originator"]
    OPEN2 --> X3(["gap now open"])

    HAS -->|yes| CREDIT["_credit(absGapBefore → absNow)<br/><i>ledger records ticks added</i>"]
    CREDIT --> PEAK{"widened past<br/>maxAbsGap?"}
    PEAK -->|yes| BUMP["maxAbsGap = absNow"]
    PEAK -->|no| DONE
    BUMP --> DONE{"abs(gapNow) ≤ threshold<br/><b>or</b> sign flipped?"}
    DONE -->|yes| CLOSE["_closeGap<br/><i>settles automatically —<br/>no one has to call settle()</i>"]
    DONE -->|no| X4(["gap stays open"])
    CLOSE --> X5(["escrow claimable"])
```

---

## 5. Gap lifecycle

Drawn as a flowchart rather than a `stateDiagram` so it imports into Excalidraw.

```mermaid
flowchart LR
    NONE(["no gap"]) -->|"abs(gap) > threshold<br/><i>beforeSwap: pre-existing</i>"| OPEN
    NONE -->|"abs(gap) > threshold<br/><i>afterSwap: this swap caused it</i>"| OPEN["<b>OPEN</b><br/>ledger accumulating<br/>surcharges escrowing"]

    OPEN -->|"widening swap"| OPEN
    OPEN -->|"narrowing swap<br/>pays surcharge"| OPEN
    OPEN -->|"abs(gap) ≤ threshold"| SETTLED
    OPEN -->|"sign flipped"| SETTLED
    OPEN -->|"block > expiryBlock<br/><i>caught on the next swap</i>"| SETTLED
    OPEN -->|"settle() called<br/>after expiry"| SETTLED

    SETTLED["<b>SETTLED</b><br/>pots fixed<br/>escrow claimable"]
    SETTLED --> TP["claimTrader<br/><i>pro-rata by contribution</i>"]
    SETTLED --> LP["claimLp<br/><i>eligible positions only</i>"]
    SETTLED -->|"after sweepGraceBlocks"| SW["sweepUnclaimed<br/><i>donates the remainder</i>"]
```

---

## 6. Settlement split — where the money goes

The exogenous case is not a branch. It is what the formula returns when nothing widened
the gap.

```mermaid
flowchart TD
    E["escrowed<br/><i>sum of surcharges</i>"] --> R["explained =<br/>totalContribution / maxAbsGap"]

    R --> T["<b>trader pot</b><br/>escrowed × traderShareBps × explained"]
    R --> L["<b>LP pot</b><br/>escrowed − trader pot"]

    T --> T1["split pro-rata by<br/>each widener's contribution"]
    L --> L1["split pro-rata by liquidity<br/>across eligible positions"]

    L1 --> EL{"eligible?"}
    EL -->|"in range at gap open<br/><b>and</b> addBlock + minAgeBlocks<br/>≤ gap open block"| PAY(["paid"])
    EL -->|"JIT — added after the gap,<br/>or topped up<br/><i>any increase resets addBlock</i>"| NO(["not paid"])

    R -.->|"<b>totalContribution = 0</b><br/>nobody in this pool<br/>caused the dislocation"| ZERO["explained = 0<br/>→ trader pot = 0<br/>→ <b>100% to LPs</b><br/><i>pure LVR compensation</i>"]

    classDef hero fill:#1f2f4a,stroke:#37a,color:#fff
    class ZERO hero
```

---

## 7. End to end — the exogenous case

The one the project exists for: the market moves, this pool sits stale, an arbitrageur
corrects it, and the LPs are compensated without anyone having caused anything.

```mermaid
sequenceDiagram
    autonumber
    participant M as Market (Binance)
    participant A as Arbitrageur
    participant PM as PoolManager
    participant H as BackdraftHook
    participant O as SplitV3Reference
    participant LP as LP

    M->>M: ETH moves 90 ticks
    Note over PM: pool tick unchanged — stale

    A->>PM: swap (close the gap)
    PM->>H: beforeSwap
    H->>O: getRefTick(id)
    O-->>H: refTick, ok, divTicks
    Note over H: abs(gapBefore) > threshold<br/>gap PRE-EXISTS this swap
    H->>H: _openGap — empty ledger
    Note over H: this swap is narrowing<br/>→ surcharged, not credited
    H->>PM: mint 6909 · BeforeSwapDelta
    PM->>H: afterSwap
    Note over H: creditable = false<br/>ledger stays empty
    H->>H: abs(gapNow) ≤ threshold → _closeGap
    Note over H: settled automatically

    LP->>H: claimLp(id, gapIdx, range, salt)
    Note over H: totalContribution = 0<br/>→ explained = 0<br/>→ trader pot = 0
    H->>PM: burn · take
    PM-->>LP: 100% of escrow
```

---

## 8. Reference price — why two pools

```mermaid
flowchart TD
    subgraph why["Measured, not assumed"]
        M1["v3 0.01%: 3.48 bps mean error<br/>on 10% of pair liquidity"]
        M2["v3 0.05%: 4.18 bps<br/>on 78% of pair liquidity"]
        M3["<b>freshness comes from trade frequency,<br/>not from depth</b>"]
        M1 --> M3
        M2 --> M3
    end

    F["v3 0.01% spot"] -->|"the price"| REF["refTick"]
    D["v3 0.05% spot"] --> DIV
    D --> TW["30-min TWAP<br/><i>observe()</i>"]
    TW --> DIV["divTicks = max(<br/>abs(deepSpot − deepTWAP),<br/>abs(fastSpot − deepSpot))"]

    DIV --> C{"divTicks vs<br/>guardMaxDevTicks"}
    C -->|"below"| ONE["multiplier = 1.00×"]
    C -->|"above"| RISE["multiplier rises linearly<br/>to maxDivMultBps"]
    C -->|"past freezeMaxDevTicks<br/><i>absurdity backstop, 0 disables</i>"| FR["ok = false → inaction"]

    ONE --> OUT(["surcharge multiplier"])
    RISE --> OUT

    NOTE["<b>Why priced and not frozen</b><br/>a freeze would have switched the hook off on<br/>37–91% of the value it exists to capture —<br/>divergent blocks ARE the moving blocks"]
    C -.-> NOTE

    classDef hero fill:#1f2f4a,stroke:#37a,color:#fff
    class NOTE hero
```

---

## 9. Attack surface

Both attacks are the same attack. No single tolerance closes both — this is a stated
limitation, not a solved problem.

```mermaid
flowchart TD
    ATT(["attacker pushes the thin<br/>v3 0.01% reference pool"])

    ATT --> M["<b>Masking</b><br/>push until the apparent gap<br/>falls below threshold"]
    ATT --> F["<b>Freezing</b><br/>push past the tolerance so<br/>the hook refuses to act"]

    M --> M2["no gap opens<br/>→ nothing is charged<br/>→ <b>the multiplier has<br/>nothing to multiply</b>"]
    M2 --> M3["break-even:<br/><b>$22k–$54k</b> arb notional<br/><i>inside ordinary trade size</i>"]

    F --> F2["under the OLD boolean guard:<br/>~$21 to silence the hook entirely"]
    F2 --> F3["fixed by pricing divergence<br/>instead of freezing on it"]

    F3 -.->|"but removing the cliff<br/>uncapped the push"| M3

    T["<b>Truncated reference</b><br/>bound reference movement to<br/>B ticks per block"] -.->|"would bound both"| M
    T -.->|"would bound both"| F
    T --> TN["measured across 3 windows<br/><b>not implemented</b>"]

    classDef bad fill:#4a1f1f,stroke:#a33,color:#fff
    classDef todo fill:#3a3212,stroke:#aa3,color:#fff
    class M3,F2 bad
    class T,TN todo
```
