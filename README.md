# SGSMM — Sortino-Gated Smart Money Mirror
### Manager Scoring Infrastructure for the Mantle Eco Fund

An autonomous on-chain trading agent on Mantle that scores DeFi managers via a rolling-Sortino classifier, routes capital through Mantle-native venues (Lendle, Init Capital, Agni Finance, Merchant Moe), and gives the Mantle Eco Fund real-time on-chain visibility into how managers compound capital. The Sortino-gating layer is the scoring mechanism; agents accrue ERC-8004 reputation in real time.

Submission for **The Turing Test Hackathon 2026** — *Alpha & Data Track / Path B [AI-Driven] Trading Strategy* (sponsored by Mirana Ventures).

> **Disclaimer**: SGSMM has no relationship to Terra's Mirror Protocol (mAssets). SGSMM mirrors **wallet positions on Mantle native protocols**, not synthetic assets.

## Why "Sortino-Gated"

Smart money mirroring is not new. Most copy-trading bots fail because they mirror indiscriminately: a wallet that posted +400% one quarter and -80% the next is treated identically to a wallet that compounds steadily. The Sharpe ratio masks this. **Sortino does not** — it penalizes only downside volatility, isolating the wallets that compound rather than oscillate.

SGSMM only mirrors wallets whose rolling 90-day Sortino exceeds 1.5, and auto-defunds positions when that Sortino decays below 0.5. Allocation, sizing, and exit are all mechanical — *not discretionary*.

## Architecture

```
Ponder Indexer (Mantle)
  ↓
Python Agent (Sortino calc + classifier + decision engine)
  ↓ tx
Solidity Vault on Mantle (USDY floor + sleeve + decision log)
  ↓ events
Next.js Dashboard (transparency: positions, decisions, equity curve)
```

ERC-8004 agent identity NFT logs every decision on-chain. Independent observers can reconstruct strategy performance entirely from on-chain data.

## Status

Pre-scaffold phase: gate verification + backtest harness in progress.

## License

MIT (see [LICENSE](./LICENSE) — added later).
