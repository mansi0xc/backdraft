"use client";

import { useEffect, useRef } from "react";

/* The identity mark: two lines, the pool tick and the true price, drifting
   through block time. Every so often a swap kicks the pool off truth, the gap
   shades ember, a closing swap snaps it shut. It never stops. You are watching
   the thing the hook watches. */

export default function HeroGap() {
  const ref = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    let raf = 0;
    let w = 0;
    let h = 0;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);

    const resize = () => {
      const r = canvas.getBoundingClientRect();
      w = r.width;
      h = r.height;
      canvas.width = w * dpr;
      canvas.height = h * dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    };
    resize();
    window.addEventListener("resize", resize);

    // ring buffer of samples, newest at the end
    const N = 520;
    const ref_: number[] = new Array(N).fill(0);
    const pool: number[] = new Array(N).fill(0);
    const open: boolean[] = new Array(N).fill(false);

    let t = 0;
    let refV = 0;
    let poolV = 0;
    let kick = 0; // remaining "held off truth" frames
    let kickDir = 1;
    let nextKick = 260;
    const THRESH = 0.34; // normalized

    // Calm on purpose: the reference barely wanders, a dislocation arrives
    // roughly every 9 to 18 seconds, holds, then eases shut.
    const step = () => {
      t += 1;
      refV += (Math.sin(t * 0.004) * 0.5 + (Math.random() - 0.5) * 0.3) * 0.006;
      refV *= 0.997;

      if (t > nextKick && kick === 0) {
        kick = 200 + ((Math.random() * 200) | 0);
        kickDir = Math.random() > 0.5 ? 1 : -1;
        poolV += kickDir * (0.34 + Math.random() * 0.34);
        nextKick = t + 540 + ((Math.random() * 560) | 0);
      }
      if (kick > 0) {
        kick -= 1;
        poolV += (Math.random() - 0.5) * 0.012;
        // closing swap: ease it shut rather than snap
        if (kick === 0) poolV += (refV - poolV) * 0.55;
      } else {
        poolV += (refV - poolV) * 0.022;
      }
      poolV = Math.max(-1.4, Math.min(1.4, poolV));

      ref_.push(refV); ref_.shift();
      pool.push(poolV); pool.shift();
      open.push(Math.abs(poolV - refV) > THRESH); open.shift();
    };

    const mid = () => h * 0.5;
    const scale = () => h * 0.30;
    const xAt = (i: number) => (i / (N - 1)) * w;
    const yAt = (v: number) => mid() - v * scale();

    const draw = () => {
      ctx.clearRect(0, 0, w, h);

      // threshold band (the blind spot: < 65 ticks)
      ctx.fillStyle = "rgba(243,236,224,0.03)";
      ctx.fillRect(0, yAt(THRESH), w, yAt(-THRESH) - yAt(THRESH));

      // gap fills
      for (let i = 1; i < N; i++) {
        if (!open[i]) continue;
        const x0 = xAt(i - 1);
        const x1 = xAt(i);
        const grad = ctx.createLinearGradient(0, mid() - scale(), 0, mid() + scale());
        grad.addColorStop(0, "rgba(226,116,60,0.22)");
        grad.addColorStop(1, "rgba(200,173,134,0.05)");
        ctx.fillStyle = grad;
        ctx.beginPath();
        ctx.moveTo(x0, yAt(pool[i - 1]));
        ctx.lineTo(x1, yAt(pool[i]));
        ctx.lineTo(x1, yAt(ref_[i]));
        ctx.lineTo(x0, yAt(ref_[i - 1]));
        ctx.closePath();
        ctx.fill();
      }

      // reference line
      ctx.strokeStyle = "rgba(120,114,104,0.9)";
      ctx.lineWidth = 1;
      ctx.beginPath();
      for (let i = 0; i < N; i++) {
        const x = xAt(i);
        const y = yAt(ref_[i]);
        i ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
      }
      ctx.stroke();

      // pool line
      const anyOpen = open[N - 1];
      ctx.strokeStyle = anyOpen ? "rgba(243,236,224,0.95)" : "rgba(243,236,224,0.72)";
      ctx.lineWidth = 1.6;
      ctx.shadowColor = anyOpen ? "rgba(226,116,60,0.6)" : "transparent";
      ctx.shadowBlur = anyOpen ? 10 : 0;
      ctx.beginPath();
      for (let i = 0; i < N; i++) {
        const x = xAt(i);
        const y = yAt(pool[i]);
        i ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
      }
      ctx.stroke();
      ctx.shadowBlur = 0;

      // leading dot
      ctx.fillStyle = anyOpen ? "#e2743c" : "#c8ad86";
      ctx.beginPath();
      ctx.arc(xAt(N - 1), yAt(pool[N - 1]), 3, 0, Math.PI * 2);
      ctx.fill();
    };

    if (reduce) {
      // one static frame with a settled gap
      for (let i = 0; i < 400; i++) step();
      draw();
      return () => window.removeEventListener("resize", resize);
    }

    let frame = 0;
    const loop = () => {
      frame += 1;
      if (frame % 2 === 0) {
        step();
        draw();
      }
      raf = requestAnimationFrame(loop);
    };
    // warm up
    for (let i = 0; i < N; i++) step();
    draw();
    raf = requestAnimationFrame(loop);

    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener("resize", resize);
    };
  }, []);

  return <canvas ref={ref} className="herofx__canvas" aria-hidden="true" />;
}
