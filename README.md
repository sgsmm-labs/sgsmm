# SGSMM — Sortino-Gated Smart Money Mirror

An autonomous on-chain trading agent on Mantle that mirrors curated smart-money wallet positions, with a rolling-Sortino classifier gating wallet eligibility and a layered vault (USDY treasury floor + capped mirror sleeve + reserve buffer).

Submission for **The Turing Test Hackathon 2026** — *Alpha & Data Track / Path B [AI-Driven] Trading Strategy* (sponsored by Mirana Ventures).

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

Day 1 of 15. Pre-scaffold phase: gate verification + backtest harness.

## License

MIT (see [LICENSE](./LICENSE) — added later).
