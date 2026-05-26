# SGSMM Backtest — Phase 1 Kill-Criterion Gate

This directory contains the Python backtest harness used to validate the Sortino-Gated Smart Money Mirror strategy *before* committing to smart contract infrastructure.

## Kill criteria

The strategy must achieve, on historical Mantle data:

- Rolling 90d Sortino ≥ 1.5
- Maximum drawdown ≤ 8%
- Win rate ≥ 55% on mirror entries
- At least 100 distinct trade events in walk-forward window

If any of the above fail, we pivot to Candidate B (Bybit↔Mantle Carry) or Candidate C (Pendle PT Curve — note: Pendle on Mantle dormant, so this fallback also needs revalidation).

## Directory structure

```
backtest/
├── README.md               # this file
├── pyproject.toml          # Python deps (pandas, numpy, web3, plotly)
├── data/                   # raw + processed historical data (gitignored)
├── notebooks/              # Jupyter exploration
│   ├── 01_data_pull.ipynb       # pull Lendle/Init/Agni/Moe events from Mantle
│   ├── 02_position_reconstruction.ipynb  # per-wallet position over time
│   ├── 03_sortino_calc.ipynb    # rolling 90d Sortino per wallet
│   ├── 04_strategy_sim.ipynb    # apply SGSMM policy in pandas
│   └── 05_proof_chart.ipynb     # SGSMM vs naive-baseline equity curve
└── src/                    # reusable Python modules
    ├── __init__.py
    ├── data_loader.py      # RPC + indexer wrappers
    ├── sortino.py          # Sortino calculator
    ├── classifier.py       # eligibility + sizing
    └── simulator.py        # walk-forward backtest engine
```

## Workflow

1. **Pull data** — `01_data_pull.ipynb` queries Mantle Mainnet RPC for historical events from Lendle, Init Capital, Agni, Merchant Moe. Cache to parquet in `data/`.
2. **Reconstruct positions** — `02_position_reconstruction.ipynb` builds per-wallet asset balances over time.
3. **Compute Sortino** — `03_sortino_calc.ipynb` calculates rolling 90d Sortino per wallet using Pyth-derived prices.
4. **Simulate strategy** — `04_strategy_sim.ipynb` applies SGSMM policy (60/40 split, Sortino gate, defund triggers) in vectorized pandas.
5. **Generate proof** — `05_proof_chart.ipynb` produces the visual proof primitive: SGSMM equity curve vs naive smart-money baseline.

## Decision gate

After notebook 5, document results in `docs-private/backtest-results.md`. If kill criteria are met, proceed to Phase 2 scaffold. If not, pivot.
