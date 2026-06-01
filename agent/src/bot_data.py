"""
Pure data layer for the SGSMM smart-money Telegram bot.

This module is deliberately Telegram-free: it loads the committed snapshot
(``agent/data/smartmoney_snapshot.json``, produced by
``agent/scripts/build_snapshot.py`` from real Mantle DEX data) and exposes pure
functions that return plain dicts/lists. That keeps every read path unit-testable
without a bot token or network access.

Verdict semantics (computed at snapshot-build time, re-derivable here):
    EMERGENCY_UNWIND  realized_dd_30d >= 0.15        (drawdown circuit-breaker)
    DEFUND            rolling_90d_sortino < 0.5      (sortino-decay)
    ENTER             label >= 0.7 AND sortino >= 1.5 AND n_obs >= 20
    SKIP              otherwise (does not clear the entry gate)
"""

from __future__ import annotations

import json
import os
from functools import lru_cache
from pathlib import Path
from typing import Any

# Snapshot path: agent/data/smartmoney_snapshot.json (this file is agent/src/bot_data.py).
_AGENT_DIR = Path(__file__).resolve().parents[1]
DEFAULT_SNAPSHOT_PATH = _AGENT_DIR / "data" / "smartmoney_snapshot.json"

# --- SGSMM classifier thresholds (mirror backtest/src/classifier.py) ----------
SORTINO_ENTRY_THRESHOLD = 1.5
SORTINO_DEFUND_THRESHOLD = 0.5
LABEL_SCORE_THRESHOLD = 0.7
MIN_OBSERVED_POSITIONS_90D = 20
REALIZED_DD_30D_THRESHOLD = 0.15


def compute_verdict(
    label_score: float,
    rolling_90d_sortino: float,
    n_observed_positions_90d: int,
    realized_dd_30d: float,
) -> str:
    """
    Apply the SGSMM eligibility policy to one wallet's latest stats.

    Evaluated as a fresh entry candidate (no capital currently mirrored), so the
    binding outcomes are ENTER vs SKIP; DEFUND / EMERGENCY_UNWIND are surfaced as
    the risk states the agent would act on if already mirroring the wallet. Check
    order matches the policy spec (emergency triggers first).
    """
    if realized_dd_30d >= REALIZED_DD_30D_THRESHOLD:
        return "EMERGENCY_UNWIND"
    if rolling_90d_sortino < SORTINO_DEFUND_THRESHOLD:
        return "DEFUND"
    if (
        label_score >= LABEL_SCORE_THRESHOLD
        and rolling_90d_sortino >= SORTINO_ENTRY_THRESHOLD
        and n_observed_positions_90d >= MIN_OBSERVED_POSITIONS_90D
    ):
        return "ENTER"
    return "SKIP"


@lru_cache(maxsize=16)
def _load_snapshot_cached(path_str: str, _mtime_ns: int) -> dict[str, Any]:
    """Internal cached loader keyed on (path, mtime_ns) so snapshot rebuilds are
    picked up automatically without an explicit cache clear."""
    path = Path(path_str)
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)


def load_snapshot(path: str | Path | None = None) -> dict[str, Any]:
    """Load (and memoize) the snapshot JSON. Pass an explicit path in tests.

    The cache is keyed on the file's mtime so a snapshot rebuild during a demo
    is reflected on the next request without requiring a manual cache clear.
    """
    resolved_path = Path(path) if path is not None else DEFAULT_SNAPSHOT_PATH
    resolved = str(resolved_path)
    if not resolved_path.exists():
        raise FileNotFoundError(
            f"snapshot not found at {resolved_path}. Generate it with: "
            "agent\\.venv\\Scripts\\python.exe agent/scripts/build_snapshot.py"
        )
    try:
        mtime_ns = os.stat(resolved).st_mtime_ns
    except OSError:
        mtime_ns = 0
    return _load_snapshot_cached(resolved, mtime_ns)


def clear_cache() -> None:
    """Drop the memoized snapshot (used by tests that load fixtures)."""
    _load_snapshot_cached.cache_clear()


def _normalize_address(address: str) -> str:
    """Lowercase + strip an EVM address for case-insensitive lookup."""
    return address.strip().lower()


def leaderboard(top_n: int = 10, snapshot: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """
    Top wallets by risk-adjusted performance (rolling 90d Sortino, then volume).

    Returns a ranked list of plain dicts. The snapshot leaderboard is already
    sorted at build time; this re-sorts defensively and trims to ``top_n``.
    """
    snap = snapshot or load_snapshot()
    rows = list(snap.get("leaderboard", []))
    rows.sort(
        key=lambda w: (w.get("rolling_90d_sortino", 0.0), w.get("n_observed_positions_90d", 0)),
        reverse=True,
    )
    top = rows[: max(0, top_n)]
    return [
        {
            "rank": idx + 1,
            "wallet_address": w["wallet_address"],
            "verdict": w["verdict"],
            "rolling_90d_sortino": w["rolling_90d_sortino"],
            "n_observed_positions_90d": w["n_observed_positions_90d"],
            "realized_dd_30d": w["realized_dd_30d"],
            "cumulative_return": w.get("cumulative_return"),
            "win_rate": w.get("win_rate"),
        }
        for idx, w in enumerate(top)
    ]


def wallet_lookup(
    address: str, snapshot: dict[str, Any] | None = None
) -> dict[str, Any] | None:
    """
    Look up a single wallet by address (case-insensitive).

    Returns the wallet's full record enriched with its leaderboard rank, or
    ``None`` if the address is not present in the snapshot.
    """
    snap = snapshot or load_snapshot()
    target = _normalize_address(address)
    if not target:
        return None

    ranked = leaderboard(top_n=len(snap.get("leaderboard", [])), snapshot=snap)
    rank_by_addr = {r["wallet_address"].lower(): r["rank"] for r in ranked}

    for w in snap.get("leaderboard", []):
        if _normalize_address(w["wallet_address"]) == target:
            record = dict(w)
            record["rank"] = rank_by_addr.get(target)
            return record

    # Address not in the trimmed leaderboard — still report any anomaly hit.
    for a in snap.get("anomalies", []):
        if _normalize_address(a["wallet_address"]) == target:
            record = dict(a)
            record["rank"] = None
            record.setdefault("note", "outside top leaderboard; flagged as an anomaly")
            return record

    return None


def signals_summary(snapshot: dict[str, Any] | None = None) -> dict[str, Any]:
    """
    Aggregate decision signals across all observed wallets.

    Returns verdict counts, the binding thresholds, dataset provenance, and a
    short list of the strongest ENTER candidates for a glanceable summary.
    """
    snap = snapshot or load_snapshot()
    meta = snap.get("meta", {})
    counts = dict(meta.get("verdict_counts", {}))

    enter_candidates = [
        {
            "wallet_address": w["wallet_address"],
            "rolling_90d_sortino": w["rolling_90d_sortino"],
            "n_observed_positions_90d": w["n_observed_positions_90d"],
        }
        for w in leaderboard(top_n=len(snap.get("leaderboard", [])), snapshot=snap)
        if w["verdict"] == "ENTER"
    ][:5]

    return {
        "latest_epoch": meta.get("latest_epoch"),
        "total_wallets": meta.get("total_wallets"),
        "epochs_observed": meta.get("epochs_observed"),
        "source": meta.get("source"),
        "verdict_counts": counts,
        "n_enter": counts.get("ENTER", 0),
        "n_skip": counts.get("SKIP", 0),
        "n_defund": counts.get("DEFUND", 0),
        "n_emergency": counts.get("EMERGENCY_UNWIND", 0),
        "n_anomalies": len(snap.get("anomalies", [])),
        "thresholds": meta.get("thresholds", {}),
        "top_enter_candidates": enter_candidates,
    }


def anomalies(top_n: int = 10, snapshot: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """
    On-chain anomaly feed: wallets breaching the drawdown / Sortino-decay gates.

    Ordered most-severe-first (largest realized 30d drawdown). Each entry carries
    a human-readable ``reason`` for why it tripped.
    """
    snap = snapshot or load_snapshot()
    rows = list(snap.get("anomalies", []))
    rows.sort(key=lambda a: a.get("realized_dd_30d", 0.0), reverse=True)
    return [dict(a) for a in rows[: max(0, top_n)]]
