# SGSMM Frontend Dashboard

Next.js 16 dashboard for the Sortino-Gated Smart Money Mirror. It visualizes the
**real backtest output** — vault capital partition, smart-money leaderboard,
decision feed, and the equity curve — and is honest about the result: on the
26-epoch window the strategy does **not** clear its kill-criterion gate
(portfolio Sortino ≈ 0.51 vs ≥ 1.5; max drawdown ≈ 9.3%).

> The dashboard is a **simulation / methodology demo**, not a live deployed
> vault. The contracts are written + tested but not yet deployed.

## Quick Start

Prerequisites: Node.js ≥ 22, pnpm.

```bash
# from repo root
pnpm frontend:dev          # or: cd frontend && pnpm dev
```

Open http://localhost:3000.

```bash
cd frontend
pnpm build && pnpm start   # production build -> .next/, served on :3000
pnpm lint                  # eslint
```

## Data Source

The dashboard reads **static JSON** generated from the real backtest results
(`../backtest/results/`). The four files in `public/data/`:

- `leaderboard.json` — wallets ranked by rolling Sortino (with verdict, dd, observations)
- `decisions.json` — ENTER / DEFUND / EMERGENCY_UNWIND decision events
- `equity.json` — NAV per epoch vs the $100k principal reference line
- `vault.json` — vault NAV + capital partition + the kill-criterion verdict
  (`portfolioSortino`, `maxDrawdownPct`, `sortinoGate`, `passesKillCriterion`)

### Regenerate dashboard data

These are produced by **`frontend/scripts/build_data.py`** (reads the backtest
CSVs/summary in `../backtest/results/`):

```bash
cd frontend
python scripts/build_data.py
```

Run this after re-running the backtest so the dashboard reflects the latest snapshot.

## Structure

Routes (`src/app/`):

- `page.tsx` — home: vault NAV, the kill-criterion disclosure banner (Sortino
  0.51, NOT cleared), key stats, and the equity-curve chart
- `vault/page.tsx` — simulated capital partition (60% floor / 30% sleeve / 10% reserve)
- `positions/page.tsx` — smart-money leaderboard table (Sortino, drawdown, verdict)
- `decisions/page.tsx` — decision feed (simulated; "would be written to the
  on-chain DecisionLog once deployed")

Components (`src/components/`): `Nav.tsx`, `EquityChart.tsx` (Recharts).
Types + JSON loaders: `src/lib/data.ts`. Styling: Tailwind CSS v4.

## Status

- ✅ All pages implemented; reads the real backtest data from `public/data/`
- ✅ Surfaces the honest verdict (`passesKillCriterion = false`)
- ⏸ Vault page is a simulated partition view — not wired to a live contract
  (Sepolia deploy pending)

There is currently no automated test suite for the frontend (the Python backtest
has `pytest`, the contracts have `forge test`).

## References

- Root README: [`../README.md`](../README.md)
- Architecture: [`../docs/architecture.md`](../docs/architecture.md)
- Next.js 16 / Tailwind v4 / Recharts docs
