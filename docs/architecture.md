# SGSMM Architecture

High-level overview of the system. Detailed strategy spec and policy thresholds are intentionally not duplicated here — they will be published in the submission writeup at Day 14.

## Components

```
┌─────────────────────────────────────────────────────────────┐
│  Ponder Indexer                                             │
│  • Indexes Mantle on-chain DeFi events                      │
│  • Tracks wallet positions across Aave/Lendle/Pendle/Moe    │
│  • Exposes Hono API for agent consumption                   │
└──────────────────────┬──────────────────────────────────────┘
                       │ Postgres
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  Python Agent (FastAPI service)                             │
│  • Wallet eligibility classifier (Sortino + label + DD)     │
│  • Decision engine (size + entry + defund)                  │
│  • Submits transactions to Vault on Mantle                  │
└──────────────────────┬──────────────────────────────────────┘
                       │ EIP-1559 tx
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  Solidity Contracts on Mantle Sepolia                       │
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
                       │ events
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  Next.js Dashboard (Vercel)                                 │
│  • Equity curve vs naive baseline (the proof chart)         │
│  • Active mirror positions table                            │
│  • Decision feed (every action transparent)                 │
│  • Agent reputation NFT view                                │
│  • Vault deposit/withdraw                                   │
└─────────────────────────────────────────────────────────────┘
```

## Data flow per cycle (24h cadence)

1. Indexer ingests Mantle on-chain events → Postgres
2. Agent fetches latest wallet positions + label refresh + price snapshot
3. Agent recomputes per-wallet rolling 90d Sortino
4. Decision engine evaluates: defund failures, deploy new entries (within caps)
5. Agent submits tx batch to Vault
6. MirrorExecutor enforces policy on-chain; DecisionLog emits events
7. Dashboard polls events; updates UI

## Why each layer exists

| Layer | Justification |
|---|---|
| Ponder Indexer | On-chain data fragmented across protocols; need normalized position view per wallet |
| Python Agent | Sortino + classifier logic too gas-intensive for on-chain; off-chain compute, on-chain enforcement |
| Vault contract | Custody + accounting on-chain so users trust deposit, can withdraw anytime |
| MirrorExecutor | Hard policy enforcement: even if agent goes rogue, caps + reserve buffer protect funds |
| DecisionLog | Verifiability requirement from Path B rubric (40% Strategy Alpha = backtest + live + on-chain records) |
| AgentIdentityNFT | ERC-8004 hackathon requirement; reputation tracks agent quality over time |
| Dashboard | Best UI/UX bonus ($3K); also helps Community Voting; transparency aid for judges |

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
