"""
SGSMM output shape-demo — synthetic equity curve.

⚠️  SYNTHETIC DATA. This does NOT validate the strategy. It exists to show the
*shape* of the project's headline output (#2 equity curve + #1 decision audit
log) before the real Mantle data pull is wired (blocked on event-ABI research).

Run:
    .venv/Scripts/python.exe scripts/demo_equity_curve.py
"""

from __future__ import annotations

import sys
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

# allow `from src...` when run from backtest/ root
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from src.simulator import run_backtest, summarize_run  # noqa: E402


def make_synthetic_panel(
    n_wallets: int = 40,
    n_epochs: int = 90,
    seed: int = 7,
) -> pd.DataFrame:
    """
    Build a synthetic per-wallet-per-epoch snapshot panel with the exact column
    contract run_backtest() expects. ~30% of wallets are 'smart' (high Sortino,
    positive drift); the rest are noise that the gate should mostly reject.
    """
    rng = np.random.default_rng(seed)
    t0 = datetime(2026, 1, 1)
    epochs = [t0 + timedelta(days=i) for i in range(n_epochs)]

    n_smart = int(n_wallets * 0.30)
    smart = {f"0x{i:040x}" for i in range(n_smart)}
    wallets = [f"0x{i:040x}" for i in range(n_wallets)]

    # Per-wallet latent quality → drives both returns and the (lagged) Sortino label.
    drift = {w: (rng.normal(0.004, 0.001) if w in smart else rng.normal(-0.0005, 0.002))
             for w in wallets}
    vol = {w: (rng.uniform(0.01, 0.02) if w in smart else rng.uniform(0.02, 0.05))
           for w in wallets}

    rows = []
    # track a trailing return window per wallet to derive a plausible rolling Sortino
    history: dict[str, list[float]] = {w: [] for w in wallets}
    for epoch in epochs:
        for w in wallets:
            r = float(rng.normal(drift[w], vol[w]))
            history[w].append(r)
            window = history[w][-90:]
            arr = np.asarray(window)
            downside = arr[arr < 0]
            dd = float(np.sqrt(np.mean(downside**2))) if downside.size else 1e-9
            mean = float(np.mean(arr))
            sortino = (mean / dd) * np.sqrt(365) if dd > 0 else 0.0
            realized_dd_30d = float(-min(0.0, np.min(np.cumsum(arr[-30:])))) if arr.size else 0.0
            rows.append(
                {
                    "epoch": epoch,
                    "wallet_address": w,
                    "label_score": 0.85 if w in smart else 0.45,
                    "rolling_90d_sortino": sortino,
                    "n_observed_positions_90d": len(window),
                    "realized_dd_30d": realized_dd_30d,
                    "wallet_return_this_epoch": r,
                }
            )
    return pd.DataFrame(rows)


def main() -> None:
    panel = make_synthetic_panel()
    state = run_backtest(panel, initial_nav=100_000.0, epoch_hours=24)
    summary = summarize_run(state, initial_nav=100_000.0)

    print("=" * 60)
    print("SGSMM — synthetic output shape-demo (NOT a strategy result)")
    print("=" * 60)
    print(f"wallets in universe : {panel['wallet_address'].nunique()}")
    print(f"epochs simulated    : {summary['n_epochs']}")
    print(f"decisions logged    : {summary['n_decisions']}")
    print(f"total return        : {summary['total_return']*100:+.2f}%")
    print(f"max drawdown        : {summary['max_drawdown']*100:.2f}%")
    print(f"sortino             : {summary['sortino']:.3f}")
    print(f"passes kill-gate    : {summary['passes_kill_criterion']}")
    print("-" * 60)

    # Output #2 — equity curve artifact
    out_dir = Path(__file__).resolve().parents[1] / "data"
    out_dir.mkdir(parents=True, exist_ok=True)
    eq = pd.DataFrame(state.equity_curve, columns=["epoch", "nav"])
    eq.to_csv(out_dir / "demo_equity_curve.csv", index=False)

    # Output #1 — decision audit log artifact (shape of the on-chain DecisionLog)
    dec = pd.DataFrame(state.decisions)
    dec.to_csv(out_dir / "demo_decision_log.csv", index=False)

    print(f"equity curve  -> {out_dir / 'demo_equity_curve.csv'}")
    print(f"decision log  -> {out_dir / 'demo_decision_log.csv'}")
    if not dec.empty:
        action_counts = dec["action"].value_counts().to_dict()
        print(f"action mix    : {action_counts}")


if __name__ == "__main__":
    main()
