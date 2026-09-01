# Backdraft — UI

A single-page, static narrative site for the Backdraft v4 hook: what we are, what
we solve, the architecture, and one interactive replay of a gap opening, accruing
a contribution ledger, and settling.

- **Framework:** Next.js 15 (App Router, static export-friendly)
- **Motion:** [Lenis](https://github.com/darkroomengineering/lenis) smooth scroll,
  a canvas signal in the hero, IntersectionObserver reveals, a scroll-progress
  hairline. All gated on `prefers-reduced-motion`.
- **Design:** synthesis of two references. Henry (editorial broadside) supplies
  the display-serif scale and the one paper inversion; Atoms (obsidian canvas,
  single champagne accent, hairline borders, no shadows) supplies the discipline.
  One hotter ember tone appears only where a gap is live. Theme is locked dark
  with a single deliberate flip for the manifesto.
- **Type:** Newsreader (broadsheet display serif, optical sizing) + Inter (UI).
- **Local dev note:** do not run `next build` while `next dev` is running on this
  folder. It corrupts `.next`. Stop the dev server first, or `rm -rf .next`.

## Run

```bash
cd ui
npm install
npm run dev
```

Open http://localhost:3000.

## The interactive piece

`components/GapReplay.tsx` — an offline replay driven by the worked example in
`../idea.md` §3, priced with captureRate 1000 bps / cap 80 bps / α 50%. Two
regimes:

- **Endogenous** — Rohan widens 180, retail widens 15, retail + Vik close.
  Ledger explains the full gap → traders get α, split 180/195 and 15/195.
- **Exogenous** — the reference jumps, the pool stays stale, Vik arbs it.
  Empty ledger → `explained = 0` → 100% to LPs, `claimTrader()` reverts.

No network calls at runtime.
