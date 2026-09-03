"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import s from "./GapReplay.module.css";

/* ---------------------------------------------------------------------------
   A faithful, offline replay of one gap's life, the mechanism from idea.md
   §3, run at two-regime scale. No network, no live data: the numbers are the
   worked example, priced with captureRate 1000bps / cap 80bps / alpha 50%.
   --------------------------------------------------------------------------- */

const N = 120;
const THRESHOLD = 65;

type Anchor = [number, number];
type Ev = {
  f: number;
  actor: string;
  kind: "widen" | "narrow" | "news";
  notional?: string;
  detail: string;
  ticks?: number; // credited widen ticks
  surchargeBps?: number;
  surchargeUsd?: number;
};

type Mode = {
  key: "endogenous" | "exogenous";
  label: string;
  blurb: string;
  pool: Anchor[];
  ref: Anchor[];
  events: Ev[];
  settleF: number;
  maxAbsGap: number;
  alpha: number;
  escrowedUsd: number;
  traderPotUsd: number;
  lpPotUsd: number;
  split: { actor: string; frac: string; usd: number }[];
  traderReverts: boolean;
};

const MODES: Mode[] = [
  {
    key: "endogenous",
    label: "Endogenous",
    blurb: "A trade moved the pool. The originating traders pay.",
    pool: [
      [0, 0],
      [12, 180],
      [40, 195],
      [64, 185],
      [96, 15],
      [120, 15],
    ],
    ref: [
      [0, 0],
      [120, 0],
    ],
    events: [
      {
        f: 12,
        actor: "Rohan, whale",
        kind: "widen",
        notional: "$1.2M",
        detail: "buys ETH, shoves the pool 180 ticks off truth",
        ticks: 180,
      },
      {
        f: 40,
        actor: "Retail",
        kind: "widen",
        notional: "$80k",
        detail: "follows the move, +15 ticks",
        ticks: 15,
      },
      {
        f: 64,
        actor: "Retail",
        kind: "narrow",
        notional: "$20k",
        detail: "partial sell back toward truth",
        surchargeBps: 19.5,
        surchargeUsd: 39,
      },
      {
        f: 96,
        actor: "Vik, arb bot",
        kind: "narrow",
        notional: "$600k",
        detail: "closes the gap, the swap that today feeds a block builder",
        surchargeBps: 19.5,
        surchargeUsd: 1170,
      },
    ],
    settleF: 108,
    maxAbsGap: 195,
    alpha: 0.5,
    escrowedUsd: 1209,
    traderPotUsd: 604.5,
    lpPotUsd: 604.5,
    split: [
      { actor: "Rohan", frac: "180 / 195", usd: 558 },
      { actor: "Retail", frac: "15 / 195", usd: 46.5 },
    ],
    traderReverts: false,
  },
  {
    key: "exogenous",
    label: "Exogenous",
    blurb: "The world moved, the pool went stale. This is LVR. LPs get all of it.",
    pool: [
      [0, 0],
      [96, 0],
      [110, 190],
      [120, 190],
    ],
    ref: [
      [0, 0],
      [18, 0],
      [24, 200],
      [120, 200],
    ],
    events: [
      {
        f: 22,
        actor: "the market",
        kind: "news",
        detail: "Binance moves 3,000 → 3,704 on news. The pool sits stale.",
      },
      {
        f: 100,
        actor: "Vik, arb bot",
        kind: "narrow",
        notional: "$600k",
        detail: "buys the underpriced ETH out of the pool",
        surchargeBps: 20,
        surchargeUsd: 1200,
      },
    ],
    settleF: 112,
    maxAbsGap: 200,
    alpha: 0.5,
    escrowedUsd: 1200,
    traderPotUsd: 0,
    lpPotUsd: 1200,
    split: [],
    traderReverts: true,
  },
];

function interp(anchors: Anchor[], f: number): number {
  if (f <= anchors[0][0]) return anchors[0][1];
  const last = anchors[anchors.length - 1];
  if (f >= last[0]) return last[1];
  for (let i = 0; i < anchors.length - 1; i++) {
    const [f0, v0] = anchors[i];
    const [f1, v1] = anchors[i + 1];
    if (f >= f0 && f <= f1) {
      const t = (f - f0) / (f1 - f0);
      return v0 + (v1 - v0) * t;
    }
  }
  return last[1];
}

// chart geometry
const W = 1000;
const H = 360;
const TOP = 26;
const BOT = 34;
const TMIN = -120;
const TMAX = 320;
const X = (f: number) => (f / N) * W;
const Y = (tick: number) =>
  TOP + (1 - (tick - TMIN) / (TMAX - TMIN)) * (H - TOP - BOT);

const usd = (n: number) =>
  n === 0
    ? "$0"
    : n < 1
      ? `$${n.toFixed(2)}`
      : `$${n.toLocaleString("en-US", { maximumFractionDigits: n < 100 ? 2 : 0 })}`;

export default function GapReplay() {
  const [modeIdx, setModeIdx] = useState(0);
  const [p, setP] = useState(0);
  const [playing, setPlaying] = useState(false);
  const raf = useRef(0);
  const mode = MODES[modeIdx];

  // autoplay
  useEffect(() => {
    if (!playing) return;
    let prev = performance.now();
    const speed = N / 6500; // frames per ms  → ~6.5s run
    const tick = (now: number) => {
      const dt = now - prev;
      prev = now;
      setP((cur) => {
        const next = cur + dt * speed;
        if (next >= N) {
          setPlaying(false);
          return N;
        }
        return next;
      });
      raf.current = requestAnimationFrame(tick);
    };
    raf.current = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf.current);
  }, [playing]);

  const reset = (i: number) => {
    setModeIdx(i);
    setP(0);
    setPlaying(false);
  };

  // sampled lines
  const { poolPts, refPts, bandTop, bandBot, openF, closeF } = useMemo(() => {
    const poolPts: string[] = [];
    const refPts: string[] = [];
    const bandTop: string[] = [];
    const bandBot: string[] = [];
    let openF = -1;
    let closeF = -1;
    for (let f = 0; f <= N; f += 1) {
      const pool = interp(mode.pool, f);
      const ref = interp(mode.ref, f);
      poolPts.push(`${X(f).toFixed(1)},${Y(pool).toFixed(1)}`);
      refPts.push(`${X(f).toFixed(1)},${Y(ref).toFixed(1)}`);
      bandTop.push(`${X(f).toFixed(1)},${Y(ref + THRESHOLD).toFixed(1)}`);
      bandBot.push(`${X(f).toFixed(1)},${Y(ref - THRESHOLD).toFixed(1)}`);
      const openNow = Math.abs(pool - ref) > THRESHOLD;
      if (openNow && openF < 0) openF = f;
      if (!openNow && openF >= 0 && closeF < 0 && f > openF) closeF = f;
    }
    if (openF >= 0 && closeF < 0) closeF = N;
    return { poolPts, refPts, bandTop, bandBot, openF, closeF };
  }, [mode]);

  // gap-fill polygon clipped to playhead
  const gapFill = useMemo(() => {
    if (openF < 0) return "";
    const end = Math.min(p, closeF);
    if (end <= openF) return "";
    const top: string[] = [];
    const bot: string[] = [];
    for (let f = openF; f <= end; f += 1) {
      top.push(`${X(f).toFixed(1)},${Y(interp(mode.pool, f)).toFixed(1)}`);
      bot.push(`${X(f).toFixed(1)},${Y(interp(mode.ref, f)).toFixed(1)}`);
    }
    return `${top.join(" ")} ${bot.reverse().join(" ")}`;
  }, [mode, p, openF, closeF]);

  const state: "dormant" | "open" | "closed" | "settled" =
    p >= mode.settleF
      ? "settled"
      : openF >= 0 && p >= openF && p < closeF
        ? "open"
        : openF >= 0 && p >= closeF
          ? "closed"
          : "dormant";

  const chipClass =
    state === "open" ? s.chipOpen : state === "settled" ? s.chipDone : "";
  const chipText =
    state === "dormant"
      ? "Dormant"
      : state === "open"
        ? "Gap open"
        : state === "closed"
          ? "Gap closed"
          : "Settled";

  const seen = mode.events.filter((e) => p >= e.f);
  const credits = seen.filter((e) => e.kind === "widen");
  const totalTicks = credits.reduce((a, e) => a + (e.ticks ?? 0), 0);
  const surcharges = seen.filter((e) => e.kind === "narrow");
  const escrow = surcharges.reduce((a, e) => a + (e.surchargeUsd ?? 0), 0);
  const explained =
    mode.maxAbsGap === 0 ? 0 : Math.min(totalTicks / mode.maxAbsGap, 1);
  const settled = p >= mode.settleF;

  const activeLine = X(p);
  const poolAtP = interp(mode.pool, p);

  return (
    <div className={s.panel}>
      <div className={s.bar}>
        <div className={s.modes}>
          {MODES.map((m, i) => (
            <button
              key={m.key}
              className={`${s.mode} ${i === modeIdx ? s.modeOn : ""}`}
              onClick={() => reset(i)}
            >
              {m.label}
            </button>
          ))}
        </div>
        <span className={`${s.chip} ${chipClass}`}>{chipText}</span>
      </div>

      <div className={s.chartWrap}>
        <svg
          className={s.chart}
          viewBox={`0 0 ${W} ${H}`}
          preserveAspectRatio="none"
          role="img"
          aria-label={`Gap lifecycle replay, ${mode.label} regime`}
        >
          {/* blind band around the reference (< 65 ticks: hook is blind) */}
          <polygon
            points={`${bandTop.join(" ")} ${[...bandBot].reverse().join(" ")}`}
            fill="var(--line-soft)"
          />
          <polyline
            points={bandTop.join(" ")}
            fill="none"
            stroke="var(--line)"
            strokeWidth="1"
            strokeDasharray="2 4"
          />
          <polyline
            points={bandBot.join(" ")}
            fill="none"
            stroke="var(--line)"
            strokeWidth="1"
            strokeDasharray="2 4"
          />

          {/* live gap fill */}
          {gapFill && (
            <polygon
              points={gapFill}
              fill={
                state === "open"
                  ? "color-mix(in oklab, var(--flame), transparent 72%)"
                  : "color-mix(in oklab, var(--ember), transparent 80%)"
              }
            />
          )}

          {/* reference line */}
          <polyline
            points={refPts.join(" ")}
            fill="none"
            stroke="var(--ash)"
            strokeWidth="1.5"
          />
          {/* pool line */}
          <polyline
            points={poolPts.join(" ")}
            fill="none"
            stroke="var(--cream)"
            strokeWidth="2"
          />

          {/* event markers on the pool line */}
          {mode.events.map((e, i) => {
            const seenIt = p >= e.f;
            const cx = X(e.f);
            const cy = Y(interp(mode.pool, e.f));
            const col =
              e.kind === "widen"
                ? "var(--cream)"
                : e.kind === "narrow"
                  ? "var(--flame)"
                  : "var(--ember)";
            return (
              <g key={i} opacity={seenIt ? 1 : 0.28}>
                <circle
                  cx={cx}
                  cy={cy}
                  r={e.kind === "news" ? 3 : 4}
                  fill={seenIt ? col : "none"}
                  stroke={col}
                  strokeWidth="1.5"
                />
              </g>
            );
          })}

          {/* playhead */}
          <line
            x1={activeLine}
            x2={activeLine}
            y1={TOP - 6}
            y2={H - BOT + 6}
            stroke="var(--ember)"
            strokeWidth="1"
          />
          <circle
            cx={activeLine}
            cy={Y(poolAtP)}
            r="4.5"
            fill="var(--ember)"
          />

          {/* labels */}
          <text className={s.serifTag} x="8" y={Y(interp(mode.pool, 0)) - 12}>
            pool
          </text>
          <text className={s.axisLabel} x="8" y={H - 12}>
            block time →
          </text>
          <text
            className={s.axisLabel}
            x={W - 8}
            y={H - 12}
            textAnchor="end"
          >
            reference, v3 0.01% spot
          </text>
        </svg>
      </div>

      <div className={s.transport}>
        <button
          className={s.play}
          onClick={() => {
            if (p >= N - 0.5) setP(0);
            setPlaying((v) => !v);
          }}
          aria-label={playing ? "Pause" : "Play"}
        >
          {playing ? (
            <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor">
              <rect x="1" y="1" width="3.4" height="10" />
              <rect x="7.6" y="1" width="3.4" height="10" />
            </svg>
          ) : (
            <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor">
              <path d="M2 1l9 5-9 5z" />
            </svg>
          )}
        </button>
        <input
          className={s.scrub}
          type="range"
          min={0}
          max={N}
          step={0.5}
          value={p}
          onChange={(e) => {
            setPlaying(false);
            setP(Number(e.target.value));
          }}
          aria-label="Scrub block time"
        />
        <span className={s.block}>blk +{Math.round(p)}</span>
      </div>

      <div className={s.readout}>
        {/* LEDGER */}
        <div className={s.cell}>
          <div className={s.cellHead}>Contribution ledger</div>
          {credits.length === 0 ? (
            <p className={s.muted}>
              Empty. {state === "dormant"
                ? "No gap yet."
                : "Nobody widened this gap. The market did."}
            </p>
          ) : (
            <>
              {credits.map((e, i) => (
                <div className={s.line} key={i}>
                  <span className={s.lineActor}>{e.actor}</span>
                  <span className={`${s.num}`}>
                    <b>+{e.ticks}</b> ticks
                  </span>
                </div>
              ))}
              <div className={s.line}>
                <span>total</span>
                <span className={s.num}>
                  <b>{totalTicks}</b> ticks
                </span>
              </div>
            </>
          )}
        </div>

        {/* ESCROW */}
        <div className={s.cell}>
          <div className={s.cellHead}>Surcharge escrow, ERC-6909</div>
          {surcharges.length === 0 ? (
            <p className={s.muted}>
              Charged only on a narrowing swap, priced on the widest the gap
              ever reached, so splitting the close saves nothing.
            </p>
          ) : (
            <>
              {surcharges.map((e, i) => (
                <div className={s.line} key={i}>
                  <span>
                    <span className={s.lineActor}>{e.actor}</span>
                    <br />
                    <span className={s.muted}>
                      {e.notional} at {e.surchargeBps} bps
                    </span>
                  </span>
                  <span className={s.num}>
                    <b>{usd(e.surchargeUsd ?? 0)}</b>
                  </span>
                </div>
              ))}
              <p className={s.big}>{usd(escrow)}</p>
              <span className={s.muted}>held against PoolManager</span>
            </>
          )}
        </div>

        {/* SETTLEMENT */}
        <div className={s.cell}>
          <div className={s.cellHead}>Settlement</div>
          {!settled ? (
            <p className={s.muted}>
              Runs when the gap closes. The trader pot scales by{" "}
              <i>explained</i> = min(ledger / peak gap, 1). A poisoning dust
              swap buys almost nothing.
            </p>
          ) : (
            <>
              <div className={s.line}>
                <span>explained</span>
                <span className={s.num}>
                  <b>{Math.round(explained * 100)}%</b>
                </span>
              </div>
              <div className={s.line}>
                <span>alpha, trader share</span>
                <span className={s.num}>{Math.round(mode.alpha * 100)}%</span>
              </div>
              <div className={s.line}>
                <span>trader pot</span>
                <span className={s.num}>
                  <b>{usd(mode.traderPotUsd)}</b>
                </span>
              </div>
              {mode.split.map((sp, i) => (
                <div className={s.line} key={i}>
                  <span className={s.muted}>
                    {sp.actor}, {sp.frac}
                  </span>
                  <span className={`${s.num} ${s.muted}`}>{usd(sp.usd)}</span>
                </div>
              ))}
              <p className={`${s.big} ${s.bigEmber}`}>{usd(mode.lpPotUsd)}</p>
              <span className={s.muted}>to eligible, seasoned LPs</span>
              {mode.traderReverts && (
                <p className={s.revert}>
                  claimTrader() reverts. The ledger is empty, so this branch
                  never runs. 100% routes to LPs with no <code>if</code>.
                </p>
              )}
            </>
          )}
        </div>
      </div>
    </div>
  );
}
