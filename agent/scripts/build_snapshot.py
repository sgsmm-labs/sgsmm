"""
Snapshot builder for the SGSMM Telegram demo bot.

Reads the proven backtest panel (``backtest/results/panel_real.csv`` — real
Mantle DEX trades reconstructed into the classifier panel) and distils it into a
small, committable JSON the bot serves at runtime: ``agent/data/smartmoney_snapshot.json``.

Pipeline:
    panel_real.csv
        -> latest-epoch row per wallet  (+ per-wallet trailing stats)
        -> apply ENTER/SKIP/DEFUND/EMERGENCY thresholds
        -> top ~50 wallets by rolling_90d_sortino + an anomalies list

The classifier thresholds are the documented SGSMM constants (kept in sync with
``backtest/src/classifier.py :: ClassifierConfig``). They are replicated here on
purpose: the bot must build its snapshot without importing the sibling backtest
package, so the data layer stays self-contained and deployable on its own.

Run (from the repo root, with the agent venv)::

    agent\\.venv\\Scripts\\python.exe agent/scripts/build_snapshot.py
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd

# --- SGSMM classifier thresholds (mirror backtest/src/classifier.py) ----------
SORTINO_ENTRY_THRESHOLD = 1.5
SORTINO_DEFUND_THRESHOLD = 0.5
LABEL_SCORE_THRESHOLD = 0.7
MIN_OBSERVED_POSITIONS_90D = 20
REALIZED_DD_30D_THRESHOLD = 0.15

TOP_N_WALLETS = 50

# Repo paths (this file lives at agent/scripts/build_snapshot.py).
_AGENT_DIR = Path(__file__).resolve().parents[1]
_REPO_ROOT = _AGENT_DIR.parent
PANEL_CSV = _REPO_ROOT / "backtest" / "results" / "panel_real.csv"
SNAPSHOT_PATH = _AGENT_DIR / "data" / "smartmoney_snapshot.json"


def _verdict(
    label_score: float,
    sortino: float,
    n_obs: int,
    realized_dd_30d: float,
) -> str:
    """
    Map a wallet's latest-epoch stats to an SGSMM action.

    Snapshot semantics: every wallet is evaluated as a *fresh entry candidate*
    (no capital currently mirrored), so the binding outcomes are ENTER vs SKIP.
    DEFUND / EMERGENCY_UNWIND are the "would-be" risk states the agent would take
    if it were already mirroring this wallet; we surface them so judges can see
    the full decision surface, and they also drive the anomalies list.

    Check order matches the policy spec (emergency triggers first).
    """
    if realized_dd_30d >= REALIZED_DD_30D_THRESHOLD:
        return "EMERGENCY_UNWIND"
    if sortino < SORTINO_DEFUND_THRESHOLD:
        return "DEFUND"
    if (
        label_score >= LABEL_SCORE_THRESHOLD
        and sortino >= SORTINO_ENTRY_THRESHOLD
        and n_obs >= MIN_OBSERVED_POSITIONS_90D
    ):
        return "ENTER"
    return "SKIP"


def _latest_per_wallet(panel: pd.DataFrame) -> pd.DataFrame:
    """Return one row per wallet: its most recent epoch observation."""
    ordered = panel.sort_values(["wallet_address", "epoch"])
    return ordered.groupby("wallet_address", as_index=False).tail(1)


def _trailing_stats(panel: pd.DataFrame) -> pd.DataFrame:
    """Per-wallet trailing aggregates over the full observed history."""
    grp = panel.groupby("wallet_address")
    ret = grp["wallet_return_this_epoch"]
    stats = pd.DataFrame(
        {
            "epochs_observed": grp.size(),
            "cumulative_return": ret.apply(lambda s: float((1.0 + s).prod() - 1.0)),
            "win_rate": ret.apply(lambda s: float((s > 0).mean()) if len(s) else 0.0),
            "peak_dd_30d": grp["realized_dd_30d"].max(),
            "peak_sortino": grp["rolling_90d_sortino"].max(),
        }
    )
    return stats.reset_index()


def build_snapshot(panel_csv: Path = PANEL_CSV) -> dict:
    """Build the snapshot dict from the panel CSV (pure; does not write)."""
    panel = pd.read_csv(panel_csv)
    missing = {
        "epoch",
        "wallet_address",
        "label_score",
        "rolling_90d_sortino",
        "n_observed_positions_90d",
        "realized_dd_30d",
        "wallet_return_this_epoch",
    } - set(panel.columns)
    if missing:
        raise ValueError(f"panel CSV missing columns: {sorted(missing)}")

    latest = _latest_per_wallet(panel)
    trailing = _trailing_stats(panel)
    merged = latest.merge(trailing, on="wallet_address", how="left")

    wallets: list[dict] = []
    for row in merged.itertuples(index=False):
        sortino = float(row.rolling_90d_sortino)
        n_obs = int(row.n_observed_positions_90d)
        dd = float(row.realized_dd_30d)
        label = float(row.label_score)
        verdict = _verdict(label, sortino, n_obs, dd)
        wallets.append(
            {
                "wallet_address": str(row.wallet_address),
                "verdict": verdict,
                "label_score": round(label, 4),
                "rolling_90d_sortino": round(sortino, 4),
                "n_observed_positions_90d": n_obs,
                "realized_dd_30d": round(dd, 4),
                "wallet_return_this_epoch": round(float(row.wallet_return_this_epoch), 6),
                "epochs_observed": int(row.epochs_observed),
                "cumulative_return": round(float(row.cumulative_return), 6),
                "win_rate": round(float(row.win_rate), 4),
                "peak_dd_30d": round(float(row.peak_dd_30d), 4),
                "last_epoch": str(row.epoch),
            }
        )

    # Leaderboard: best risk-adjusted first, then trim to the committable top-N.
    wallets.sort(
        key=lambda w: (w["rolling_90d_sortino"], w["n_observed_positions_90d"]),
        reverse=True,
    )
    top_wallets = wallets[:TOP_N_WALLETS]

    # Anomalies: drawdown breaches or emergency-unwind candidates (most severe first).
    anomalies = [
        {
            "wallet_address": w["wallet_address"],
            "verdict": w["verdict"],
            "realized_dd_30d": w["realized_dd_30d"],
            "rolling_90d_sortino": w["rolling_90d_sortino"],
            "reason": (
                "realized_dd_30d >= 0.15 (emergency-unwind trigger)"
                if w["realized_dd_30d"] >= REALIZED_DD_30D_THRESHOLD
                else "rolling_90d_sortino < 0.5 (sortino-decay defund)"
            ),
        }
        for w in wallets
        if w["verdict"] in ("EMERGENCY_UNWIND", "DEFUND")
    ]
    anomalies.sort(key=lambda a: a["realized_dd_30d"], reverse=True)

    verdict_counts: dict[str, int] = {}
    for w in wallets:
        verdict_counts[w["verdict"]] = verdict_counts.get(w["verdict"], 0) + 1

    latest_epoch = str(panel["epoch"].max())
    return {
        "meta": {
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "source": "backtest/results/panel_real.csv (real Mantle DEX trades)",
            "latest_epoch": latest_epoch,
            "total_wallets": len(wallets),
            "epochs_observed": int(panel["epoch"].nunique()),
            "thresholds": {
                "sortino_entry_threshold": SORTINO_ENTRY_THRESHOLD,
                "sortino_defund_threshold": SORTINO_DEFUND_THRESHOLD,
                "label_score_threshold": LABEL_SCORE_THRESHOLD,
                "min_observed_positions_90d": MIN_OBSERVED_POSITIONS_90D,
                "realized_dd_30d_threshold": REALIZED_DD_30D_THRESHOLD,
            },
            "verdict_counts": verdict_counts,
        },
        "leaderboard": top_wallets,
        "anomalies": anomalies,
    }


def main() -> None:
    """CLI entry: build the snapshot from the real panel and write the JSON."""
    if not PANEL_CSV.exists():
        raise SystemExit(f"panel CSV not found: {PANEL_CSV}")

    snapshot = build_snapshot(PANEL_CSV)
    SNAPSHOT_PATH.parent.mkdir(parents=True, exist_ok=True)
    SNAPSHOT_PATH.write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")

    meta = snapshot["meta"]
    print(f"wrote {SNAPSHOT_PATH}")
    print(f"  total wallets observed : {meta['total_wallets']}")
    print(f"  leaderboard wallets    : {len(snapshot['leaderboard'])}")
    print(f"  anomalies              : {len(snapshot['anomalies'])}")
    print(f"  latest epoch           : {meta['latest_epoch']}")
    print(f"  verdict counts         : {meta['verdict_counts']}")


if __name__ == "__main__":
    main()
