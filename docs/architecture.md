# SGSMM Architecture

High-level overview of the system design and component interactions. This document describes the **architecture and infrastructure**, not deployment status. See the root README for current status.

> **IMPORTANT: Current Status**  
> Contracts are **written and tested** (see `contracts/test/`) but **NOT YET DEPLOYED** to Mantle Sepolia. The indexer runs locally on Lendle lending events + L1 bridge arrivals. The strategy is validated via backtest on real historical data but does **not yet clear its kill-criterion gate** — a 90-day-gated policy cannot be validated on the 26-epoch window (positions open in only ~7 of 26 epochs; needs ≥90 days), so `passes_kill_criterion = false` despite a promising sleeve-alpha Sortino ≈ 3.3. This document describes the full system design *as intended*, not the current operational state.

## Components

```
┌─────────────────────────────────────────────────────────────┐
│  Ponder Indexer (LOCAL)                                     │
│  • Indexes Mantle lending events (Lendle)                   │
│  • Tracks Ethereum→Mantle L1 bridge arrivals                │
│  • Exposes REST API for eligible wallets                    │
└──────────────────────┬──────────────────────────────────────┘
                       │ (local dev only)
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  Python Agent (FastAPI service — PROTOTYPE)                 │
│  • Wallet eligibility classifier (Sortino + label + DD)     │
│  • Decision engine logic (size + entry + defund)            │
│  • [NOT YET] Submits transactions to Vault on Mantle        │
└──────────────────────┬──────────────────────────────────────┘
                       │ [pending deployment]
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  Solidity Contracts (WRITTEN + TESTED, not deployed)        │
│  ┌─────────────────┐  ┌────────────────────┐                │
│  │ SGSMMVault.sol  │  │ MirrorExecutor.sol │                │
│  │ ERC-4626        │  │ Policy enforcement │                │
│  │ 60/40 split     │  │ Per-pos/wallet cap │                │
│  └────────┬────────┘  └────────┬───────────┘                │
│           │                    │                            │
│           ▼                    ▼                            │
│  ┌─────────────────┐  ┌────────────────────┐                │
│  │ DecisionLog.sol │  │ AgentIdentityNFT   │                │
│  │ event Decision  │  │ ERC-8004 reputation│                │
│  └─────────────────┘  └────────────────────┘                │
└──────────────────────┬──────────────────────────────────────┘
                       │ [contract code exists; events not yet emitted]
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  Next.js Dashboard (LOCAL)                                  │
│  • Equity curve vs naive baseline (backtest proof chart)    │
│  • Simulated mirror positions table                         │
│  • Decision feed (from backtest decision panel)             │
│  • Vault deposit/withdraw UI (not yet connected)            │
└─────────────────────────────────────────────────────────────┘
```

## Data flow per cycle (24h cadence — INTENDED)

1. Indexer ingests Mantle on-chain events → Postgres
2. Agent fetches latest wallet positions + label refresh + price snapshot
3. Agent recomputes per-wallet rolling 90d Sortino
4. Decision engine evaluates: defund failures, deploy new entries (within caps)
5. Agent submits tx batch to Vault
6. MirrorExecutor enforces policy on-chain; DecisionLog emits events
7. Dashboard polls events; updates UI

**Current state:** Steps 1–4 are implemented and validated via backtest. Steps 5–7 require on-chain deployment (pending Phase 2 gate clearance).

## Why each layer exists

| Layer | Justification | Status |
|---|---|---|
| Ponder Indexer | On-chain data fragmented across protocols; need normalized position view per wallet | ✓ Implemented (local; indexes Lendle + L1 bridge) |
| Python Agent | Sortino + classifier logic too gas-intensive for on-chain; off-chain compute, on-chain enforcement | ✓ Implemented (decision logic validated via backtest) |
| Vault contract | Custody + accounting on-chain so users trust deposit, can withdraw anytime | ✓ Written & tested; deployment pending |
| MirrorExecutor | Hard policy enforcement: even if agent goes rogue, caps + reserve buffer protect funds | ✓ Written & tested; deployment pending |
| DecisionLog | Verifiability requirement from Path B rubric (40% Strategy Alpha = backtest + live + on-chain records) | ✓ Written & tested; deployment pending |
| AgentIdentityNFT | ERC-8004 hackathon requirement; reputation tracks agent quality over time | ✓ Written & tested; deployment pending |
| Dashboard | Best UI/UX bonus ($3K); also helps Community Voting; transparency aid for judges | ✓ Implemented (displays backtest results) |

## Repository structure (planned)

```
SGSMM/
├── README.md
├── LICENSE
├── .gitignore
├── docs/                # public architecture + setup
│   └── architecture.md  # ← this file
├── docs-private/        # gitignored strategy + roadmap
├── contracts/           # Foundry workspace
│   ├── foundry.toml
│   ├── src/
│   │   ├── SGSMMVault.sol
│   │   ├── MirrorExecutor.sol
│   │   ├── DecisionLog.sol
│   │   └── AgentIdentityNFT.sol
│   ├── test/
│   └── script/
├── indexer/             # Ponder
│   ├── ponder.config.ts
│   ├── ponder.schema.ts
│   ├── src/
│   │   └── index.ts
│   └── abis/
├── agent/               # Python FastAPI
│   ├── pyproject.toml
│   ├── src/
│   │   ├── main.py
│   │   ├── sortino.py
│   │   ├── classifier.py
│   │   ├── decision.py
│   │   └── tx.py
│   ├── backtest/        # Jupyter notebooks + historical analysis
│   └── tests/
└── frontend/            # Next.js 16
    ├── package.json
    ├── app/
    │   ├── page.tsx
    │   ├── vault/
    │   ├── positions/
    │   └── decisions/
    └── components/
```
