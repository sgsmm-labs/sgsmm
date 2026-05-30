"""
SGSMM Phase-1 real-data backtest runner.

End-to-end on REAL Mantle on-chain DEX trades (Dune `dex.trades`, blockchain
= 'mantle'), replacing the synthetic harness:

    dune_source.load_trades(csv)   # real Merchant Moe / Agni / Uniswap swaps
        -> panel.build_panel_from_trades
        -> simulator.run_backtest
        -> simulator.summarize_run   # kill-criterion verdict

Prefilter: wallets with < MIN_TRADES total swaps can never satisfy the
classifier's "n_observed_positions_90d >= 20" gate, so they are guaranteed
SKIPs and are dropped before reconstruction. This does not change the equity
curve (they never receive capital) — it only avoids reconstructing millions of
one-shot wallets. The daily VWAP price panel is dominated by high-volume actors,
who are exactly the wallets retained, so mark-to-market is essentially unaffected.

Usage:
    python run_real_backtest.py [csv_path] [min_trades]
Defaults: data/mantle_dex_trades.csv, min_trades=20
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import pandas as pd

from src.classifier import ClassifierConfig
from src.dune_source import load_trades
from src.panel import build_panel_from_trades
from src.simulator import run_backtest, summarize_run

HERE = Path(__file__).resolve().parent
CSV = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "data" / "mantle_dex_trades.csv"
MIN_TRADES = int(sys.argv[2]) if len(sys.argv) > 2 else 20
RESULTS = HERE / "results"


def banner(msg: str) -> None:
    print(f"\n{'=' * 70}\n{msg}\n{'=' * 70}", flush=True)


def main() -> None:
    t0 = time.time()
    banner(f"LOAD  {CSV}")
    trades = load_trades(csv_path=str(CSV))
    span = (trades["day"].min(), trades["day"].max())
    print(
        f"trades={len(trades):,}  wallets={trades['wallet'].nunique():,}  "
        f"days={trades['day'].nunique()}  span={span[0].date()}..{span[1].date()}",
        flush=True,
    )

    # Prefilter: drop guaranteed-SKIP wallets (< MIN_TRADES total swaps).
    counts = trades.groupby("wallet").size()
    keep = counts[counts >= MIN_TRADES].index
    active = trades[trades["wallet"].isin(keep)].copy()
    print(
        f"prefilter >= {MIN_TRADES} trades:  kept {len(keep):,} wallets "
        f"({len(keep) / trades['wallet'].nunique():.1%}), "
        f"{len(active):,} trades ({len(active) / len(trades):.1%} of volume rows)",
        flush=True,
    )

    banner("BUILD PANEL (reconstruct FIFO PnL -> rolling Sortino/DD)")
    t1 = time.time()
    panel = build_panel_from_trades(active)
    print(
        f"panel rows={len(panel):,}  wallets={panel['wallet_address'].nunique():,}  "
        f"epochs={panel['epoch'].nunique()}  ({time.time() - t1:.1f}s)",
        flush=True,
    )

    # Eligibility diagnostics (does any real wallet clear the Sortino gate?)
    cfg = ClassifierConfig()
    elig = panel[
        (panel["label_score"] >= cfg.label_score_threshold)
        & (panel["rolling_90d_sortino"] >= cfg.sortino_entry_threshold)
        & (panel["n_observed_positions_90d"] >= cfg.min_observed_positions_90d)
    ]
    print(
        f"ENTER-eligible wallet-epochs={len(elig):,}  "
        f"unique eligible wallets={elig['wallet_address'].nunique():,}",
        flush=True,
    )
    s = panel["rolling_90d_sortino"]
    print(
        f"sortino: nonzero={int((s != 0).sum()):,}  "
        f">=1.5={int((s >= 1.5).sum()):,}  max={s.max():.2f}  "
        f"p99={s.quantile(0.99):.2f}",
        flush=True,
    )

    banner("RUN BACKTEST (Sortino-gated smart-money mirror)")
    t2 = time.time()
    state = run_backtest(panel)
    summary = summarize_run(state)
    print(f"({time.time() - t2:.1f}s)", flush=True)

    # Decision breakdown
    if state.decisions:
        dec = pd.DataFrame(state.decisions)["action"].value_counts().to_dict()
    else:
        dec = {}
    print(f"decisions by action: {dec}", flush=True)

    banner("KILL-CRITERION VERDICT")
    for k, v in summary.items():
        print(f"  {k:24} {v}", flush=True)

    try:
        RESULTS.mkdir(parents=True, exist_ok=True)
        panel.to_csv(RESULTS / "panel_real.csv", index=False)
        pd.DataFrame(state.equity_curve, columns=["epoch", "nav"]).to_csv(
            RESULTS / "equity_real.csv", index=False
        )
        (RESULTS / "summary_real.json").write_text(json.dumps(summary, indent=2, default=str))
        print(f"\nartifacts -> {RESULTS}  (total {time.time() - t0:.1f}s)", flush=True)
    except Exception as e:  # noqa: BLE001
        print(f"\n[warn] artifact write failed ({e}); verdict above is authoritative", flush=True)


if __name__ == "__main__":
    main()
