"use client";

import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import s from "./ArchMap.module.css";

/* An architecture map you can pan, zoom, and pull apart. Built for the demo:
   hit "Play the flow" and it walks the gap through the hook, one fire point
   at a time. Drag any node to rearrange it on camera. */

type Kind = "src" | "hook" | "state" | "out";
type NodeDef = {
  id: number;
  x: number;
  y: number;
  w: number;
  h: number;
  kind: Kind;
  title: string;
  sub: string[];
  fire?: boolean;
};

const KIND_LABEL: Record<Kind, string> = {
  src: "external",
  hook: "hook",
  state: "storage",
  out: "payout",
};

const NODES: NodeDef[] = [
  { id: 1, x: 0, y: 130, w: 208, h: 90, kind: "src", title: "v3 0.01%", sub: ["fast spot", "the reference"] },
  { id: 2, x: 0, y: 330, w: 208, h: 90, kind: "src", title: "v3 0.05%", sub: ["deep spot + 30m TWAP", "the guard"] },
  { id: 3, x: 288, y: 230, w: 234, h: 92, kind: "src", title: "SplitV3Reference", sub: ["getRefTick to (tick, ok)", "ok = false freezes the hook"] },
  { id: 4, x: 600, y: 60, w: 226, h: 102, kind: "hook", title: "beforeSwap", fire: true, sub: ["classify narrowing", "open gap, mint surcharge"] },
  { id: 5, x: 600, y: 350, w: 226, h: 102, kind: "hook", title: "afterSwap", fire: true, sub: ["delta gap, credit tx.origin", "raise maxAbsGap, close gap"] },
  { id: 6, x: 906, y: 50, w: 218, h: 90, kind: "state", title: "PoolManager", sub: ["ERC-6909 escrow", "BeforeSwapDelta from swapper"] },
  { id: 7, x: 906, y: 280, w: 218, h: 98, kind: "state", title: "Gap ledger", sub: ["contribution, totalContribution", "maxAbsGap, escrowed"] },
  { id: 8, x: 1204, y: 165, w: 226, h: 102, kind: "hook", title: "settle()", fire: true, sub: ["explained = min(ledger / peak, 1)", "traderPot, lpPot"] },
  { id: 9, x: 1204, y: 370, w: 236, h: 98, kind: "hook", title: "claimTrader / claimLp", sub: ["pro rata, age + duration filter", "sum claimable <= balance"] },
  { id: 10, x: 1510, y: 268, w: 198, h: 90, kind: "out", title: "Traders + LPs", sub: ["_payout", "IUnlockCallback"] },
];

type EdgeDef = { from: number; to: number; label: string };
const EDGES: EdgeDef[] = [
  { from: 1, to: 3, label: "spot tick" },
  { from: 2, to: 3, label: "TWAP guard" },
  { from: 3, to: 4, label: "refTick + ok" },
  { from: 4, to: 6, label: "mint surcharge" },
  { from: 4, to: 7, label: "open gap" },
  { from: 5, to: 7, label: "credit + maxAbsGap" },
  { from: 6, to: 8, label: "escrowed" },
  { from: 5, to: 8, label: "gap closed" },
  { from: 7, to: 8, label: "ledger + peak" },
  { from: 8, to: 9, label: "traderPot / lpPot" },
  { from: 9, to: 10, label: "_payout" },
];
const eid = (e: EdgeDef) => `${e.from}-${e.to}`;

type Step = { nodes: number[]; edges: string[]; cap: string; fire?: boolean };
const STEPS: Step[] = [
  { nodes: [1, 2, 3], edges: ["1-3", "2-3"], cap: "Two v3 pools feed the price. The deep pool guards the fast one against manipulation." },
  { nodes: [3, 4], edges: ["3-4"], cap: "beforeSwap reads getRefTick. If ok is false the reference is unreliable and the hook freezes here, no credit, no surcharge." },
  { nodes: [4, 7], edges: ["4-7"], cap: "Gap already past 65 ticks and none open: beforeSwap opens the gap with an empty ledger.", fire: true },
  { nodes: [5, 7], edges: ["5-7"], cap: "A widening swap. afterSwap credits tx.origin by the ticks it added and raises maxAbsGap." },
  { nodes: [4, 6], edges: ["4-6"], cap: "A narrowing swap. beforeSwap mints an ERC-6909 surcharge priced on the peak gap, so splitting the close saves nothing.", fire: true },
  { nodes: [5, 7], edges: ["5-7"], cap: "The closing swap pulls back or overshoots the reference. afterSwap closes the gap.", fire: true },
  { nodes: [6, 7, 8], edges: ["6-8", "7-8"], cap: "settle: explained = min(totalContribution / maxAbsGap, 1). traderPot = escrowed x alpha x explained. An empty ledger sends everything to LPs with no branch.", fire: true },
  { nodes: [8, 9, 10], edges: ["8-9", "9-10"], cap: "Pull claims. LPs filtered by age, top-up resets the clock, duration weighting separates a seasoned LP from a one-block bot. Solvency asserted every step." },
];

const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v));

export default function ArchMap() {
  const wrapRef = useRef<HTMLDivElement>(null);
  const svgRef = useRef<SVGSVGElement>(null);

  const [posById, setPosById] = useState<Record<number, { x: number; y: number }>>(
    () => Object.fromEntries(NODES.map((n) => [n.id, { x: n.x, y: n.y }]))
  );
  const [view, setView] = useState({ x: 0, y: 0, k: 1 });
  const viewRef = useRef(view);
  viewRef.current = view;
  const [step, setStep] = useState<number | null>(null);
  const [playing, setPlaying] = useState(false);
  const [grabbing, setGrabbing] = useState(false);

  const drag = useRef<
    | { mode: "pan"; lx: number; ly: number }
    | { mode: "node"; id: number; lx: number; ly: number }
    | null
  >(null);
  const playTimer = useRef<number | null>(null);

  const boxOf = useCallback(
    (ids: number[], pad = 0) => {
      const ns = NODES.filter((n) => ids.includes(n.id));
      const x1 = Math.min(...ns.map((n) => posById[n.id]?.x ?? n.x)) - pad;
      const y1 = Math.min(...ns.map((n) => posById[n.id]?.y ?? n.y)) - pad;
      const x2 = Math.max(...ns.map((n) => (posById[n.id]?.x ?? n.x) + n.w)) + pad;
      const y2 = Math.max(...ns.map((n) => (posById[n.id]?.y ?? n.y) + n.h)) + pad;
      return { x: x1, y: y1, w: x2 - x1, h: y2 - y1 };
    },
    [posById]
  );
  const allIds = NODES.map((n) => n.id);
  const contentBox = useMemo(() => boxOf(allIds), [boxOf]); // eslint-disable-line

  const fit = useCallback(
    (box = contentBox, minK = 0.55, maxK = 1.15) => {
      const el = wrapRef.current;
      if (!el) return;
      const pad = 48;
      const cw = el.clientWidth;
      const ch = el.clientHeight;
      const k = clamp(
        Math.min((cw - pad * 2) / box.w, (ch - pad * 2) / box.h),
        minK,
        maxK
      );
      const overflowsX = box.w * k > cw - pad * 2;
      setView({
        k,
        x: overflowsX ? pad - box.x * k : (cw - box.w * k) / 2 - box.x * k,
        y: Math.min((ch - box.h * k) / 2, 64) - box.y * k,
      });
    },
    [contentBox]
  );

  const fitRef = useRef(fit);
  fitRef.current = fit;
  const boxOfRef = useRef(boxOf);
  boxOfRef.current = boxOf;

  useLayoutEffect(() => {
    const intro = () => fitRef.current(boxOfRef.current([1, 2, 3], 44), 0.5, 0.95);
    intro();
    const id = requestAnimationFrame(intro);
    return () => cancelAnimationFrame(id);
  }, []);

  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    let w0 = el.clientWidth;
    let h0 = el.clientHeight;
    const ro = new ResizeObserver(() => {
      const e = wrapRef.current;
      if (!e) return;
      if (Math.abs(e.clientWidth - w0) < 2 && Math.abs(e.clientHeight - h0) < 2)
        return;
      w0 = e.clientWidth;
      h0 = e.clientHeight;
      fitRef.current(boxOfRef.current([1, 2, 3], 44), 0.5, 0.95);
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // zoom toward the cursor, non-passive wheel
  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      const r = el.getBoundingClientRect();
      const mx = e.clientX - r.left;
      const my = e.clientY - r.top;
      setView((v) => {
        const k = clamp(v.k * Math.exp(-e.deltaY * 0.0016), 0.3, 2.6);
        const wx = (mx - v.x) / v.k;
        const wy = (my - v.y) / v.k;
        return { k, x: mx - wx * k, y: my - wy * k };
      });
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  }, []);

  const zoomBy = (factor: number) => {
    const el = wrapRef.current;
    if (!el) return;
    const mx = el.clientWidth / 2;
    const my = el.clientHeight / 2;
    setView((v) => {
      const k = clamp(v.k * factor, 0.3, 2.6);
      const wx = (mx - v.x) / v.k;
      const wy = (my - v.y) / v.k;
      return { k, x: mx - wx * k, y: my - wy * k };
    });
  };

  const onPointerDownBg = (e: React.PointerEvent) => {
    (e.target as Element).setPointerCapture?.(e.pointerId);
    drag.current = { mode: "pan", lx: e.clientX, ly: e.clientY };
    setGrabbing(true);
  };
  const onPointerDownNode = (e: React.PointerEvent, id: number) => {
    e.stopPropagation();
    (e.currentTarget as Element).setPointerCapture(e.pointerId);
    drag.current = { mode: "node", id, lx: e.clientX, ly: e.clientY };
    setGrabbing(true);
  };
  const onPointerMove = (e: React.PointerEvent) => {
    const d = drag.current;
    if (!d) return;
    const dx = e.clientX - d.lx;
    const dy = e.clientY - d.ly;
    d.lx = e.clientX;
    d.ly = e.clientY;
    if (d.mode === "pan") {
      setView((v) => ({ ...v, x: v.x + dx, y: v.y + dy }));
    } else {
      const k = viewRef.current.k;
      setPosById((p) => ({
        ...p,
        [d.id]: { x: p[d.id].x + dx / k, y: p[d.id].y + dy / k },
      }));
    }
  };
  const endDrag = () => {
    drag.current = null;
    setGrabbing(false);
  };

  const stopPlay = useCallback(() => {
    if (playTimer.current) window.clearTimeout(playTimer.current);
    playTimer.current = null;
    setPlaying(false);
  }, []);

  const runStep = useCallback(
    (i: number) => {
      setStep(i);
      const st = STEPS[i];
      fit(boxOf(st.nodes, 90), 0.45, 1.35);
      const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
      if (i < STEPS.length - 1) {
        playTimer.current = window.setTimeout(
          () => runStep(i + 1),
          reduce ? 4600 : 3600
        );
      } else {
        playTimer.current = null;
        setPlaying(false);
      }
    },
    [fit, boxOf]
  );

  const play = () => {
    stopPlay();
    setPlaying(true);
    const start = step === null || step >= STEPS.length - 1 ? 0 : step;
    setStep(null);
    setTimeout(() => runStep(start), 20);
  };
  const reset = () => {
    stopPlay();
    setStep(null);
    setPosById(Object.fromEntries(NODES.map((n) => [n.id, { x: n.x, y: n.y }])));
    setTimeout(
      () => fitRef.current(boxOfRef.current([1, 2, 3], 44), 0.5, 0.95),
      20
    );
  };

  useEffect(() => () => stopPlay(), [stopPlay]);

  const st = step === null ? null : STEPS[step];
  const nodeHot = (id: number) => (st ? st.nodes.includes(id) : false);
  const edgeHot = (id: string) => (st ? st.edges.includes(id) : false);
  const anySel = st !== null;

  const anchor = (id: number, side: "l" | "r") => {
    const n = NODES.find((x) => x.id === id)!;
    const p = posById[id];
    return { x: p.x + (side === "r" ? n.w : 0), y: p.y + n.h / 2 };
  };
  const edgePath = (e: EdgeDef) => {
    const a = anchor(e.from, "r");
    const b = anchor(e.to, "l");
    const mx = (a.x + b.x) / 2;
    return `M${a.x},${a.y} C${mx},${a.y} ${mx},${b.y} ${b.x},${b.y}`;
  };

  return (
    <div ref={wrapRef} className={s.wrap}>
      <svg
        ref={svgRef}
        className={`${s.svg} ${grabbing ? s.grabbing : ""}`}
        onPointerDown={onPointerDownBg}
        onPointerMove={onPointerMove}
        onPointerUp={endDrag}
        onPointerCancel={endDrag}
      >
        <defs>
          <marker id="am-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
            <path d="M0,0 L10,5 L0,10 z" fill="var(--ash)" />
          </marker>
          <marker id="am-arrow-hot" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
            <path d="M0,0 L10,5 L0,10 z" fill="var(--ember)" />
          </marker>
        </defs>

        <g
          transform={`translate(${view.x},${view.y}) scale(${view.k})`}
          style={{
            transition: playing
              ? "transform 0.8s cubic-bezier(0.16,1,0.3,1)"
              : "none",
          }}
        >
          {/* edges */}
          {EDGES.map((e) => {
            const id = eid(e);
            const hot = edgeHot(id);
            const a = anchor(e.from, "r");
            const b = anchor(e.to, "l");
            const mx = (a.x + b.x) / 2;
            const my = (a.y + b.y) / 2;
            return (
              <g key={id} opacity={anySel && !hot ? 0.16 : 1}>
                <path
                  className={`${s.edge} ${hot ? s.edgeHot : ""}`}
                  d={edgePath(e)}
                  markerEnd={hot ? "url(#am-arrow-hot)" : "url(#am-arrow)"}
                />
                <rect
                  className={s.edgeLabelBg}
                  x={mx - e.label.length * 3.2}
                  y={my - 8}
                  width={e.label.length * 6.4}
                  height={16}
                  rx={2}
                />
                <text className={s.edgeLabel} x={mx} y={my + 3.5} textAnchor="middle">
                  {e.label}
                </text>
              </g>
            );
          })}

          {/* nodes */}
          {NODES.map((n) => {
            const p = posById[n.id];
            const hot = nodeHot(n.id);
            return (
              <g
                key={n.id}
                className={`${s.node} ${hot ? s.hot : ""} ${n.fire ? s.fire : ""}`}
                transform={`translate(${p.x},${p.y})`}
                opacity={anySel && !hot ? 0.22 : 1}
                onPointerDown={(e) => onPointerDownNode(e, n.id)}
              >
                <rect width={n.w} height={n.h} rx={2} />
                {n.fire && <circle className={s.dot} cx={n.w - 14} cy={14} r={3.5} />}
                <text className={`${s.nKind} ${n.fire ? s.fireTag : ""}`} x={16} y={22}>
                  {n.fire ? "ignition" : KIND_LABEL[n.kind]}
                </text>
                <text className={s.nTitle} x={16} y={46}>
                  {n.title}
                </text>
                {n.sub.map((line, i) => (
                  <text key={i} className={s.nSub} x={16} y={66 + i * 15}>
                    {line}
                  </text>
                ))}
              </g>
            );
          })}
        </g>
      </svg>

      <p className={s.hint}>
        Drag to pan. Scroll to zoom. Drag any node to move it. Orange dots are the
        points where the hook acts.
      </p>

      <div className={s.controls}>
        <button className={s.btn} onClick={() => zoomBy(1 / 1.25)} aria-label="Zoom out">
          &minus;
        </button>
        <span className={s.zoomRead}>{Math.round(view.k * 100)}%</span>
        <button className={s.btn} onClick={() => zoomBy(1.25)} aria-label="Zoom in">
          +
        </button>
        <button className={s.btn} onClick={reset}>
          Reset
        </button>
        <button
          className={`${s.btn} ${s.btnPrimary}`}
          onClick={playing ? stopPlay : play}
        >
          {playing
            ? "Stop"
            : step !== null && step >= STEPS.length - 1
              ? "Replay"
              : "Play the flow"}
        </button>
      </div>

      {st && (
        <div className={s.cap}>
          <span className={s.capStep}>
            {String(step! + 1).padStart(2, "0")} / {String(STEPS.length).padStart(2, "0")}
          </span>
          <span className={s.capText}>{st.cap}</span>
        </div>
      )}
    </div>
  );
}
