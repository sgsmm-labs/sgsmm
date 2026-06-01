# SGSMM — Sortino-Gated Smart Money Mirror

An autonomous on-chain agent for Mantle that mirrors smart-money DEX wallets, gated by a rolling 90-day Sortino ratio (enter when Sortino ≥ 1.5, auto-defund when < 0.5), with a 30-day realized-drawdown circuit-breaker (emergency unwind at ≥ 15%).

**One-line pitch:** Mirror only the managers whose downside-adjusted returns survive the gate — mechanically, and verifiably on Mantle.

**Submitted for:** The Turing Test Hackathon 2026 — *Mirana Ventures "AI Alpha & Data" Track (Path B: AI-Driven Trading Strategy)*.

> **Disclaimer:** SGSMM has no relationship to Terra's Mirror Protocol (mAssets). SGSMM mirrors **wallet positions on Mantle native protocols**, not synthetic assets.

---

## Architecture

This is a full-stack monorepo combining Python backtest infrastructure, an autonomous bot agent, a Ponder indexer, a Next.js dashboard, and Solidity vault contracts:

| Component | Language | Purpose |
|---|---|---|
| **backtest** | Python (Jupyter + pandas) | Validate Sortino gate on ~300k real Mantle DEX trades; produce decision panel |
| **agent** | Python (FastAPI + python-telegram-bot) | Autonomous runtime + Telegram bot for smart-money leaderboard & signals |
| **indexer** | TypeScript (Ponder + Hono) | Index Lendle lending events + Ethereum→Mantle L1 bridge arrivals; expose GraphQL + REST API for eligible wallets & decisions |
| **frontend** | TypeScript (Next.js 16 + Recharts) | Dashboard: vault overview, positions, leaderboard, decision feed, equity curve |
| **contracts** | Solidity (Foundry) | ERC-4626 vault (USDY floor + sleeve, 10% reserve) + on-chain DecisionLog for verifiability |

---

## Quick Start

### Prerequisites

- **Node.js** ≥ 22.0.0  
- **Python** ≥ 3.12  
- **pnpm** (package manager; `npm install -g pnpm`)
- **Foundry** (for contracts; see [foundry.paradigm.xyz](https://foundry.paradigm.xyz))

### All packages

```bash
# Install dependencies
pnpm install

# Run all dev servers in parallel
pnpm dev

# Build all packages
pnpm build

# Run all tests
pnpm test

# Lint all packages
pnpm lint
```

---

## Per-Package Commands

### Backtest (`backtest/`)

Reconstructs FIFO realized PnL + Modified-Dietz daily returns from ~300k real Mantle DEX trades (Dune `dex.trades`), then applies the rolling-90d Sortino gate. Produces the decision panel (`results/panel_real.csv`) that feeds the bot and dashboard.

**Setup:**
```bash
cd backtest
python -m venv .venv
.venv\Scripts\pip install -e ".[dev]"
```

**Run the real backtest** (end-to-end: Dune trades → FIFO PnL → rolling Sortino → decision panel):
```bash
cd backtest
.venv\Scripts\python.exe run_real_backtest.py
```
Outputs land in `results/` (`panel_real.csv`, `equity_real.csv`, `summary_real.json`).

**Methodology notebooks** (step-by-step walkthrough in `notebooks/`):
- `notebooks/01_data_pull.ipynb` — Pull Mantle DEX trades from Dune (`dex.trades`)
- `notebooks/02_position_reconstruction.ipynb` — Per-wallet FIFO position + PnL over time
- `notebooks/03_sortino_calc.ipynb` — Rolling 90d Sortino per wallet
- `notebooks/04_strategy_sim.ipynb` — Apply SGSMM policy (Sortino gate, defund triggers)
- `notebooks/05_proof_chart.ipynb` — Equity curve vs $100k principal floor

**Lint & tests:**
```bash
cd backtest
ruff check .
pytest
```

---

### Agent (`agent/`)

Autonomous agent runtime + Telegram smart-money tracker bot. The bot serves:
- `/leaderboard` — Top wallets by Sortino
- `/wallet <address>` — Verdict + stats for a single wallet
- `/signals` — Aggregate ENTER / DEFUND / EMERGENCY counts
- `/anomaly` — Wallets breaching the drawdown circuit-breaker
- `/start`, `/help` — Intro + command list

**Setup:**
```bash
cd agent
python -m venv .venv
.venv\Scripts\pip install -e ".[dev]"
```

**Configure bot token:**
1. Get a token from BotFather in Telegram (`/newbot`)
2. Create `agent/.env` with `TELEGRAM_BOT_TOKEN=<your_token>`
3. Copy `agent/.env.example` as a template

**Run bot** (from `agent/`):
```bash
# First time: build the snapshot from the real Mantle panel
.venv\Scripts\python.exe scripts/build_snapshot.py

# Start the bot (long-polls Telegram; Ctrl+C to stop)
.venv\Scripts\python.exe -m src.bot
```

**Or via installed console scripts:**
```bash
cd agent
.venv\Scripts\sgsmm-bot       # = python -m src.bot
.venv\Scripts\sgsmm-agent     # FastAPI runtime
```

**Tests (offline, no token required):**
```bash
cd agent
.venv\Scripts\python.exe -m pytest tests/test_bot_data.py -v
```

---

### Indexer (`indexer/`)

Ponder-based indexer for Mantle Mainnet (Lendle lending events) + Ethereum→Mantle L1 bridge arrivals. Exposes GraphQL, SQL-over-HTTP, and custom REST endpoints.

**Run from repo root:**
```bash
pnpm indexer:dev
```

**Or directly:**
```bash
cd indexer
pnpm dev
```

**API endpoints** (default: `http://localhost:42069`):
- `GET /health` — Service status + indexed tables
- `GET /wallets/eligible?min_sortino=1500000&limit=20` — Eligible wallets ranked by Sortino (micros)
- `GET /wallets/:address` — Single wallet + recent decisions
- `GET /decisions/recent?limit=10` — Recent decisions feed

**Environment variables:** Copy `.env.example` to `.env.local` and set:
- `PONDER_RPC_URL_5000` — Mantle Mainnet RPC
- `PONDER_RPC_URL_1` — Ethereum Mainnet RPC
- `PONDER_RPC_URL_5003` — Mantle Sepolia RPC (post-deploy)

See `indexer/README.md` for full config details.

---

### Frontend (`frontend/`)

Next.js 16 dashboard displaying vault overview, positions, leaderboard, decision feed, and equity curve.

**Run from repo root:**
```bash
pnpm frontend:dev
```

**Or directly:**
```bash
cd frontend
pnpm dev
```

Open [http://localhost:3000](http://localhost:3000) in your browser.

**Build for production:**
```bash
cd frontend
pnpm build
pnpm start
```

---

### Contracts (`contracts/`)

Solidity ERC-4626 vault + on-chain DecisionLog on Mantle Sepolia. Built with Foundry.

**Build:**
```bash
cd contracts
forge build
```

**Test (35 passing tests):**
```bash
cd contracts
forge test
```

**Format:**
```bash
cd contracts
forge fmt
```

**Deploy (post-gate-validation):**
```bash
cd contracts
forge script script/Deploy.s.sol --rpc-url <mantle_sepolia_rpc> --private-key <key>
```

See `contracts/README.md` for full deployment guide.

---

## Data & Provenance

SGSMM was run end-to-end on a **preliminary 26-epoch window** of real Mantle DEX trade data (~300,000 trades) pulled via Dune (`dex.trades`). This is an **infrastructure + methodology demonstration, not a profitability claim.**

**Honest result:** on this **26-epoch** window the strategy does **not** clear its kill-criterion gate — and the *reason* matters. A 90-day-gated policy needs ≥ 90 days of data; on 26 days the gate can only fire near the end, so the sleeve actually holds positions in just **7 of 26 epochs**. Over that thin window the strategy shows *promising* alpha (sleeve-only Sortino ≈ **3.3**; blended ≈ **3.3** including the 60% USDY floor that lifts the ratio) — but 7 active epochs is far too few to validate, so `passes_kill_criterion = false`. The value here is that the full pipeline (Dune trades → FIFO PnL → rolling Sortino → gate → decision panel → bot / dashboard / on-chain log) runs on real on-chain data and reports the verdict mechanically — including when the honest verdict is "insufficient data."

**What works today:**
- Backtest runner implements and *evaluates* the kill-criterion gate (Sortino ≥ 1.5, plus drawdown / win-rate / trade-count floors) on real trades
- Agent bot serves the smart-money leaderboard + ENTER / DEFUND / EMERGENCY signals over Telegram
- Indexer indexes Lendle lending events + L1 bridge arrivals and exposes eligible-wallet / decision endpoints
- Contracts define ERC-4626 vault mechanics + an on-chain DecisionLog (35 passing Foundry tests)
- Dashboard visualizes the real decision panel, leaderboard, and equity curve

**Not yet done:**
- A window where the strategy actually clears the gate (extended / regime-spanning validation is future work)
- Live on-chain agent execution and rebalancing (contracts are written + tested, not yet deployed)
- Any forward / out-of-sample performance claim

---

## Development

### Monorepo Scripts

```bash
pnpm dev       # Run all dev servers in parallel
pnpm build     # Build all packages
pnpm test      # Run all tests
pnpm lint      # Lint all packages
```

### Project Structure

```
sgsmm/
├── backtest/          # Python: gate validation + backtester
├── agent/             # Python: Telegram bot + FastAPI runtime
├── indexer/           # TypeScript: Ponder indexer + REST API
├── frontend/          # TypeScript: Next.js dashboard
├── contracts/         # Solidity: ERC-4626 vault + DecisionLog
├── docs/              # Public documentation
├── docs-private/      # Strategy & results (local only)
├── package.json       # Monorepo root (pnpm workspace)
└── README.md          # This file
```

---

## License

MIT (see [LICENSE](./LICENSE))

---

## Hackathon Attribution

Built for **The Turing Test Hackathon 2026**, Mirana Ventures "AI Alpha & Data" track, Mantle ecosystem.
