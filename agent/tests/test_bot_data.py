"""
Unit tests for the SGSMM bot data layer (``src.bot_data``).

These tests run entirely offline against the committed snapshot — no Telegram
token, no network. They cover leaderboard ordering, wallet lookup (hit/miss,
case-insensitivity), anomaly detection/ordering, the aggregate signal summary,
and the verdict logic across all four policy branches.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

# Make the agent package importable (tests/ -> agent/ -> src/).
_AGENT_DIR = Path(__file__).resolve().parents[1]
if str(_AGENT_DIR) not in sys.path:
    sys.path.insert(0, str(_AGENT_DIR))

from src import bot_data  # noqa: E402

SNAPSHOT_PATH = _AGENT_DIR / "data" / "smartmoney_snapshot.json"


@pytest.fixture(scope="module")
def snapshot() -> dict:
    """Load the committed snapshot once for the module."""
    assert SNAPSHOT_PATH.exists(), (
        f"snapshot missing at {SNAPSHOT_PATH}; run agent/scripts/build_snapshot.py"
    )
    bot_data.clear_cache()
    return bot_data.load_snapshot(SNAPSHOT_PATH)


# --- snapshot integrity -------------------------------------------------------


def test_snapshot_shape(snapshot: dict) -> None:
    assert set(snapshot.keys()) >= {"meta", "leaderboard", "anomalies"}
    assert snapshot["meta"]["total_wallets"] > 0
    assert isinstance(snapshot["leaderboard"], list)
    assert isinstance(snapshot["anomalies"], list)


def test_snapshot_thresholds_match_policy(snapshot: dict) -> None:
    th = snapshot["meta"]["thresholds"]
    assert th["sortino_entry_threshold"] == bot_data.SORTINO_ENTRY_THRESHOLD
    assert th["sortino_defund_threshold"] == bot_data.SORTINO_DEFUND_THRESHOLD
    assert th["label_score_threshold"] == bot_data.LABEL_SCORE_THRESHOLD
    assert th["min_observed_positions_90d"] == bot_data.MIN_OBSERVED_POSITIONS_90D
    assert th["realized_dd_30d_threshold"] == bot_data.REALIZED_DD_30D_THRESHOLD


# --- leaderboard --------------------------------------------------------------


def test_leaderboard_respects_top_n(snapshot: dict) -> None:
    rows = bot_data.leaderboard(top_n=5, snapshot=snapshot)
    assert len(rows) == 5
    assert [r["rank"] for r in rows] == [1, 2, 3, 4, 5]


def test_leaderboard_sorted_desc_by_sortino(snapshot: dict) -> None:
    rows = bot_data.leaderboard(top_n=20, snapshot=snapshot)
    sortinos = [r["rolling_90d_sortino"] for r in rows]
    assert sortinos == sorted(sortinos, reverse=True)


def test_leaderboard_zero_top_n_is_empty(snapshot: dict) -> None:
    assert bot_data.leaderboard(top_n=0, snapshot=snapshot) == []


def test_leaderboard_rows_have_required_fields(snapshot: dict) -> None:
    row = bot_data.leaderboard(top_n=1, snapshot=snapshot)[0]
    for field in (
        "rank",
        "wallet_address",
        "verdict",
        "rolling_90d_sortino",
        "n_observed_positions_90d",
        "realized_dd_30d",
    ):
        assert field in row


# --- wallet lookup ------------------------------------------------------------


def test_wallet_lookup_hit(snapshot: dict) -> None:
    known = snapshot["leaderboard"][0]["wallet_address"]
    rec = bot_data.wallet_lookup(known, snapshot=snapshot)
    assert rec is not None
    assert rec["wallet_address"].lower() == known.lower()
    assert rec["rank"] == 1


def test_wallet_lookup_is_case_insensitive(snapshot: dict) -> None:
    known = snapshot["leaderboard"][0]["wallet_address"]
    upper = bot_data.wallet_lookup(known.upper(), snapshot=snapshot)
    lower = bot_data.wallet_lookup(known.lower(), snapshot=snapshot)
    assert upper is not None and lower is not None
    assert upper["wallet_address"] == lower["wallet_address"]


def test_wallet_lookup_whitespace_tolerant(snapshot: dict) -> None:
    known = snapshot["leaderboard"][0]["wallet_address"]
    rec = bot_data.wallet_lookup(f"  {known}  ", snapshot=snapshot)
    assert rec is not None


def test_wallet_lookup_miss(snapshot: dict) -> None:
    assert bot_data.wallet_lookup("0xdeadbeef", snapshot=snapshot) is None
    assert bot_data.wallet_lookup("", snapshot=snapshot) is None


# --- anomalies ----------------------------------------------------------------


def test_anomalies_ordered_by_drawdown_desc(snapshot: dict) -> None:
    rows = bot_data.anomalies(top_n=15, snapshot=snapshot)
    dds = [a["realized_dd_30d"] for a in rows]
    assert dds == sorted(dds, reverse=True)


def test_anomalies_all_breach_a_gate(snapshot: dict) -> None:
    for a in bot_data.anomalies(top_n=50, snapshot=snapshot):
        breaches_dd = a["realized_dd_30d"] >= bot_data.REALIZED_DD_30D_THRESHOLD
        breaches_sortino = a["rolling_90d_sortino"] < bot_data.SORTINO_DEFUND_THRESHOLD
        assert breaches_dd or breaches_sortino
        assert a["verdict"] in ("EMERGENCY_UNWIND", "DEFUND")


def test_anomalies_respects_top_n(snapshot: dict) -> None:
    assert len(bot_data.anomalies(top_n=3, snapshot=snapshot)) <= 3


# --- signals summary ----------------------------------------------------------


def test_signals_summary_counts_are_consistent(snapshot: dict) -> None:
    s = bot_data.signals_summary(snapshot=snapshot)
    counts = s["verdict_counts"]
    assert s["n_enter"] == counts.get("ENTER", 0)
    assert s["n_defund"] == counts.get("DEFUND", 0)
    assert s["n_emergency"] == counts.get("EMERGENCY_UNWIND", 0)
    # Every observed wallet lands in exactly one verdict bucket.
    assert sum(counts.values()) == s["total_wallets"]


def test_signals_enter_candidates_are_enter(snapshot: dict) -> None:
    s = bot_data.signals_summary(snapshot=snapshot)
    # Candidates are drawn from the leaderboard; confirm they exist there as ENTER.
    enter_addrs = {
        w["wallet_address"]
        for w in snapshot["leaderboard"]
        if w["verdict"] == "ENTER"
    }
    for c in s["top_enter_candidates"]:
        assert c["wallet_address"] in enter_addrs


# --- verdict logic ------------------------------------------------------------


def test_verdict_enter() -> None:
    assert bot_data.compute_verdict(1.0, 2.0, 30, 0.05) == "ENTER"


def test_verdict_skip_when_sortino_below_entry_but_above_defund() -> None:
    # Sortino in [0.5, 1.5): clears defund gate, fails entry gate -> SKIP.
    assert bot_data.compute_verdict(1.0, 1.0, 30, 0.05) == "SKIP"


def test_verdict_skip_when_too_few_observations() -> None:
    assert bot_data.compute_verdict(1.0, 2.0, 5, 0.05) == "SKIP"


def test_verdict_skip_when_label_too_low() -> None:
    assert bot_data.compute_verdict(0.5, 2.0, 30, 0.05) == "SKIP"


def test_verdict_defund_on_low_sortino() -> None:
    assert bot_data.compute_verdict(1.0, 0.3, 100, 0.05) == "DEFUND"


def test_verdict_emergency_on_drawdown() -> None:
    assert bot_data.compute_verdict(1.0, 9.0, 100, 0.2) == "EMERGENCY_UNWIND"


def test_verdict_emergency_takes_priority_over_defund() -> None:
    # Both low Sortino and high drawdown — emergency wins (checked first).
    assert bot_data.compute_verdict(1.0, 0.1, 100, 0.5) == "EMERGENCY_UNWIND"


def test_verdict_boundary_dd_exactly_threshold_is_emergency() -> None:
    assert bot_data.compute_verdict(1.0, 9.0, 100, 0.15) == "EMERGENCY_UNWIND"


def test_verdict_boundary_sortino_exactly_entry_is_enter() -> None:
    assert bot_data.compute_verdict(1.0, 1.5, 20, 0.0) == "ENTER"


# --- snapshot verdicts agree with compute_verdict -----------------------------


def test_snapshot_verdicts_match_compute_verdict(snapshot: dict) -> None:
    for w in snapshot["leaderboard"]:
        expected = bot_data.compute_verdict(
            w["label_score"],
            w["rolling_90d_sortino"],
            w["n_observed_positions_90d"],
            w["realized_dd_30d"],
        )
        assert w["verdict"] == expected, w["wallet_address"]
