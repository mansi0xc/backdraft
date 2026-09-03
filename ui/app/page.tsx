import Image from "next/image";
import Reveal from "@/components/Reveal";
import GapReplay from "@/components/GapReplay";
import ArchMap from "@/components/ArchMap";
import HeroGap from "@/components/HeroGap";

export default function Page() {
  return (
    <main>
      <nav className="nav">
        <a href="#top" className="nav__mark" style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
          <Image src="/logo.png" alt="Backdraft" width={30} height={30} style={{ display: "block" }} />
          Backdraft
        </a>
        <span className="nav__meta">UHI10 · HK-UHI10-1088</span>
      </nav>

      {/* ---------------------------------------------------------------- HERO */}
      <header id="top" className="section section--flush herofx">
        <HeroGap />
        <div className="wrap hero2">
          <Reveal>
            <p className="sh__ey" style={{ marginBottom: 0 }}>
              Uniswap v4 hook
            </p>
          </Reveal>
          <Reveal delay={60}>
            <h1 className="hero2__head">
              The pool is sitting on <span className="it">money.</span>
            </h1>
          </Reveal>
          <Reveal delay={120}>
            <p className="hero2__sub">
              A Uniswap v4 hook that reclaims the mispricing a swap leaves
              behind, for the pool&apos;s own traders and LPs. It never runs the
              arbitrage and never fetches a price off-chain.
            </p>
          </Reveal>
          <Reveal delay={180}>
            <div className="hero2__row">
              <a href="#replay" className="cta">
                Watch a gap open
              </a>
              <a href="#architecture" className="cta cta__ghost">
                How it works
              </a>
            </div>
          </Reveal>
        </div>
      </header>

      {/* ------------------------------------------------------------- THE SCENE */}
      <section className="section">
        <div className="wrap">
          <Reveal>
            <div className="sh">
              <h2 className="sh__h">
                A pool quoting the wrong price is{" "}
                <span className="it">money on a table.</span>
              </h2>
              <p className="sh__b">
                One ETH/USDC pool: 100 ETH, 300,000 USDC, price 3,000, Binance
                3,000. Rohan buys 10 ETH and pays 33,333 USDC. That overpayment
                is price impact, the cost of consuming depth. Not a bug. But the
                pool now quotes 3,704 while the world still says 3,000. Vik the
                arb bot buys 10 ETH on Binance for 30,000, sells into the pool
                for 33,333, and hands most of the profit to a block builder for
                ordering.
              </p>
            </div>
          </Reveal>

          <Reveal delay={80}>
            <table className="ledger">
              <thead>
                <tr>
                  <th>Pool marked to truth</th>
                  <th>ETH</th>
                  <th>USDC</th>
                  <th>Value at 3,000</th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td>Start</td>
                  <td>100</td>
                  <td>300,000</td>
                  <td>600,000</td>
                </tr>
                <tr className="row-mark">
                  <td>After Rohan</td>
                  <td>90</td>
                  <td>333,333</td>
                  <td>603,333</td>
                </tr>
                <tr>
                  <td>After Vik</td>
                  <td>100</td>
                  <td>300,000</td>
                  <td>600,000</td>
                </tr>
              </tbody>
            </table>
          </Reveal>

          <Reveal delay={120}>
            <p
              className="prose"
              style={{ marginTop: "2rem", fontSize: "1.05rem" }}
            >
              For one moment the pool was <strong>$3,333 richer</strong>. It
              held the value, then handed all of it back.
            </p>
          </Reveal>
        </div>
      </section>

      {/* -------------------------------------------------------- MANIFESTO */}
      <section className="section section--flush manifesto">
        <div className="wrap">
          <Reveal>
            <p className="manifesto__q">
              The surcharge is not a new charge on anyone. It is the pool{" "}
              <span className="mk">declining to hand back</span> what is already
              sitting in its own reserves.
            </p>
          </Reveal>
          <Reveal delay={100}>
            <p className="manifesto__foot">
              Rohan cannot be charged. He already paid, and the payment landed
              in the pool. Backdraft keeps a slice of that value in escrow when a
              swap narrows the gap, then splits it at settlement.
            </p>
          </Reveal>
        </div>
      </section>

      {/* ------------------------------------------------------------- REPLAY */}
      <section id="replay" className="section">
        <div className="wrap">
          <Reveal>
            <div className="sh" style={{ maxWidth: "30ch" }}>
              <span className="sh__ey">Watch one gap live</span>
              <h2 className="sh__h">
                The whole mechanism, in{" "}
                <span className="it">fifteen seconds.</span>
              </h2>
              <p className="sh__b">
                Scrub through block time. White is the pool tick, grey is the
                reference. Inside the dashed band the gap is under 65 ticks and
                the hook is blind by design. Switch regimes: the code has no{" "}
                <code
                  style={{
                    fontFamily: "var(--font-sans)",
                    color: "var(--ember)",
                    fontStyle: "normal",
                  }}
                >
                  if
                </code>{" "}
                for the exogenous case. An empty ledger is the attribution
                result.
              </p>
            </div>
          </Reveal>
          <Reveal delay={80}>
            <GapReplay />
          </Reveal>
        </div>
      </section>

      {/* ------------------------------------------------------- TWO REGIMES */}
      <section className="section">
        <div className="wrap">
          <Reveal>
            <div className="sh">
              <h2 className="sh__h">
                Two regimes, <span className="it">one hook.</span> The split
                falls out of the ledger.
              </h2>
            </div>
          </Reveal>

          <Reveal delay={80}>
            <div className="regime">
              <div className="regime__col">
                <span className="regime__k">Endogenous</span>
                <p className="regime__q">A trade moved the pool.</p>
                <dl>
                  <div>
                    <dt>Trigger</dt>
                    <dd>A swap knocks the pool off truth</dd>
                  </div>
                  <div>
                    <dt>Who pays</dt>
                    <dd>The originating traders</dd>
                  </div>
                  <div>
                    <dt>Ledger</dt>
                    <dd>Populated, explains the full gap</dd>
                  </div>
                  <div>
                    <dt>Settlement</dt>
                    <dd>Traders get alpha, pro rata on contribution</dd>
                  </div>
                </dl>
              </div>
              <div className="regime__col">
                <span className="regime__k">Exogenous, LVR</span>
                <p className="regime__q">The world moved, the pool went stale.</p>
                <dl>
                  <div>
                    <dt>Trigger</dt>
                    <dd>Information arrives, no trade does</dd>
                  </div>
                  <div>
                    <dt>Who pays</dt>
                    <dd>The LPs, loss versus rebalancing</dd>
                  </div>
                  <div>
                    <dt>Ledger</dt>
                    <dd>Empty, explained is 0</dd>
                  </div>
                  <div>
                    <dt>Settlement</dt>
                    <dd>100% to LPs, no branch</dd>
                  </div>
                </dl>
              </div>
            </div>
          </Reveal>

          <Reveal delay={120}>
            <p className="prose" style={{ marginTop: "2rem" }}>
              The earlier design used a binary <em>empty ledger means exogenous</em>
              . That was poisonable: one dust swap reclassifies a 200 tick gap
              as endogenous and claws the trader share back from LPs. Now the
              trader pot scales by{" "}
              <strong>explained = min(totalContribution / maxAbsGap, 1)</strong>.
              Two manufactured ticks on a 200 tick gap buy 1% of the pot, less
              than the dust swap costs to make.
            </p>
          </Reveal>
        </div>
      </section>

      {/* ----------------------------------------------------- ARCHITECTURE */}
      <section id="architecture" className="section">
        <div className="wrap">
          <Reveal>
            <div className="sh" style={{ maxWidth: "26ch" }}>
              <span className="sh__ey">Architecture</span>
              <h2 className="sh__h">
                All of it lives in pool state, never the{" "}
                <span className="it">mempool.</span>
              </h2>
              <p className="sh__b">
                A gap opens, accrues a ledger, and settles across the swap and
                liquidity path. Drag it around, zoom in, or play the flow to
                walk one gap through the hook.
              </p>
            </div>
          </Reveal>

          <Reveal delay={80}>
            <ArchMap />
          </Reveal>

          <Reveal delay={120}>
            <div className="split split--even" style={{ marginTop: "3.5rem" }}>
              <div>
                <p className="regime__k">The reference price</p>
                <p className="prose" style={{ marginTop: "0.8rem" }}>
                  Not the deepest pool, the <strong>most traded</strong>. The v3
                  0.01% ETH/USDC spot tick was the most corrected source across
                  calm, volatile, USDT stressed, and one second truth
                  conditions. An own pool EMA is 16.6 times worse: a pool cannot
                  detect its own staleness from its own history.
                </p>
              </div>
              <div>
                <p className="regime__k">Split from the guard</p>
                <p className="prose" style={{ marginTop: "0.8rem" }}>
                  The fast pool is fresh but thin, 5% of pair liquidity would
                  corrupt it. So the deep v3 0.05% pool guards it. If{" "}
                  <strong>deep spot drifts from deep TWAP</strong>, or{" "}
                  <strong>fast spot drifts from deep spot</strong>, by more than
                  50 ticks, the hook freezes. No credit, no surcharge. An
                  unreliable reference produces inaction, not a wrong charge.
                </p>
              </div>
            </div>
          </Reveal>

          <Reveal delay={160}>
            <div className="statrow">
              <p className="stat">
                <b>65</b>
                <span>gap threshold in ticks, from measured p100 error</span>
              </p>
              <p className="stat">
                <b>50</b>
                <span>guard deviation in ticks, 6.6% to 10.1% freeze</span>
              </p>
              <p className="stat">
                <b>74k</b>
                <span>reference gas, two stage read on the swap path</span>
              </p>
              <p className="stat">
                <b>228 to 58</b>
                <span>worst case error in bps, cut by the guard</span>
              </p>
            </div>
          </Reveal>
        </div>
      </section>

      {/* ------------------------------------------------------- DIFFERENCE */}
      <section className="section">
        <div className="wrap">
          <Reveal>
            <div className="sh" style={{ maxWidth: "26ch" }}>
              <h2 className="sh__h">
                Everything else runs the arbitrage or fetches a price off-chain.{" "}
                <span className="it">Backdraft does neither.</span>
              </h2>
            </div>
          </Reveal>

          <Reveal delay={60}>
            <div className="usp">
              <div className="usp__row">
                <span className="usp__i">i</span>
                <p className="usp__t">Reference chosen by measured accuracy</p>
                <p className="usp__d">
                  Four market conditions, one consistent ordering. The source
                  that gets corrected most often wins. We report the margin
                  rather than claim a magnitude.
                </p>
              </div>
              <div className="usp__row">
                <span className="usp__i">ii</span>
                <p className="usp__t">Reference split from guard across fee tiers</p>
                <p className="usp__d">
                  Freshest source for the price, deepest source for manipulation
                  detection. The only arrangement that gets both properties at
                  once.
                </p>
              </div>
              <div className="usp__row">
                <span className="usp__i">iii</span>
                <p className="usp__t">Threshold derived from measured p100 error</p>
                <p className="usp__d">
                  65 ticks is the max of a 14,351 block window, with the honest
                  note that a two day max is not a bound. Deployments must
                  monitor realized error and version the threshold.
                </p>
              </div>
            </div>
          </Reveal>

          <Reveal delay={100}>
            <div className="pa">
              <div className="pa__c">
                <p className="pa__n">WhatTheHook</p>
                <p className="pa__d">
                  Runs the arb itself, needs two or more connected pools, no path
                  for the exogenous case.
                </p>
              </div>
              <div className="pa__c">
                <p className="pa__n">Detox Hook</p>
                <p className="pa__d">
                  Pyth to detect arb, capture, redirect. Fixed payee, no
                  attribution, no trader leg.
                </p>
              </div>
              <div className="pa__c">
                <p className="pa__n">ArbHook, Chainlink CRE</p>
                <p className="pa__d">Off-chain compute, LPs only.</p>
              </div>
              <div className="pa__c">
                <p className="pa__n">Truncated Oracle</p>
                <p className="pa__d">
                  Caps per block tick movement. Publishes a price, does not
                  detect its own staleness.
                </p>
              </div>
              <div className="pa__c">
                <p className="pa__n">am-AMM, LVR auctions</p>
                <p className="pa__d">
                  Auction the right to be the arbitrageur. Never touch the trader
                  who created the opportunity.
                </p>
              </div>
              <div className="pa__c">
                <p className="pa__n">Where we stand</p>
                <p className="pa__d">
                  The fee tier ordering is in the literature and reading external
                  pools is not new. Doing all three at once has no precedent we
                  can find.
                </p>
              </div>
            </div>
          </Reveal>
        </div>
      </section>

      {/* -------------------------------------------------------- DRAWBACKS */}
      <section className="section">
        <div className="wrap">
          <Reveal>
            <div className="sh" style={{ maxWidth: "22ch" }}>
              <h2 className="sh__h">
                The blind spot is <span className="it">exactly</span> where the
                action is.
              </h2>
            </div>
          </Reveal>
          <Reveal delay={60}>
            <div className="flaws2">
              <div>
                <h4>We will surcharge genuine traders</h4>
                <p>
                  No on-chain signal separates a bot from someone who happened
                  to sell into a stale quote. We frame it as a price on consuming
                  a stale quote, not a penalty on intent, and it nets out over
                  time.
                </p>
              </div>
              <div>
                <h4>Blind below 65 ticks, frozen in roughly 10% of volatile blocks</h4>
                <p>
                  Plausibly the very blocks where dislocation value concentrates.
                  The dollar weighted share lost to the blind spot is a never cut
                  measurement and goes in the README either way.
                </p>
              </div>
              <div>
                <h4>Claim economics exclude small participants</h4>
                <p>
                  Pull based, per gap, per address. A retail rebate is often
                  smaller than the gas to claim it, so in practice the trader leg
                  pays whales and bots.
                </p>
              </div>
              <div>
                <h4>tx.origin attribution</h4>
                <p>
                  Works through the Universal Router, breaks for ERC-4337 and
                  batched transactions. The demo uses direct swaps.
                </p>
              </div>
              <div>
                <h4>This is capture, not elimination</h4>
                <p>
                  The arbitrage still happens and price discovery still works. We
                  change who keeps the proceeds, from a block builder to the
                  pool&apos;s own participants.
                </p>
              </div>
            </div>
          </Reveal>
        </div>
      </section>

      {/* ---------------------------------------------------------- FOOTER */}
      <footer className="section section--flush">
        <div className="wrap foot">
          <Reveal>
            <p className="foot__big">
              Most pools cannot tell who created the mispricing they are sitting
              on. Backdraft can.
            </p>
          </Reveal>
          <Reveal delay={60}>
            <div className="foot__meta">
              <span>Mansi &amp; Roshan</span>
              <span>UHI10 · HK-UHI10-1088</span>
              <span>Uniswap v4 · Foundry</span>
              <span>No partner integrations</span>
            </div>
          </Reveal>
        </div>
      </footer>
    </main>
  );
}
