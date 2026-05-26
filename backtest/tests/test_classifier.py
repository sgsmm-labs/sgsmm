"""Unit tests for classifier.py — policy enforcement correctness."""

from __future__ import annotations

import pandas as pd
import pytest

from src.classifier import (
    ClassifierConfig,
    EligibilityAction,
    WalletSnapshot,
    classify_batch,
    classify_wallet,
    size_new_entry,
)


def _snap(**kw):
    """Builder with sensible defaults that pass all gates."""
    defaults = {
        "wallet_address": "0xabc",
        "label_score": 0.8,
        "rolling_90d_sortino": 1.8,
        "n_observed_positions_90d": 25,
        "realized_dd_30d": 0.05,
        "current_allocation_pct": 0.0,
    }
    defaults.update(kw)
    return WalletSnapshot(**defaults)


def test_eligible_wallet_enters():
    assert classify_wallet(_snap()) == EligibilityAction.ENTER


def test_low_label_score_skips():
    assert classify_wallet(_snap(label_score=0.4)) == EligibilityAction.SKIP


def test_low_sortino_skips():
    assert classify_wallet(_snap(rolling_90d_sortino=1.0)) == EligibilityAction.SKIP


def test_few_observations_skips():
    assert classify_wallet(_snap(n_observed_positions_90d=5)) == EligibilityAction.SKIP


def test_existing_position_holds():
    snap = _snap(current_allocation_pct=0.05)
    # Still eligible (Sortino still high, DD still low) → HOLD
    assert classify_wallet(snap) == EligibilityAction.HOLD


def test_sortino_decay_defunds_existing():
    snap = _snap(current_allocation_pct=0.05, rolling_90d_sortino=0.3)
    assert classify_wallet(snap) == EligibilityAction.DEFUND


def test_drawdown_emergency_unwinds():
    snap = _snap(current_allocation_pct=0.05, realized_dd_30d=0.20)
    assert classify_wallet(snap) == EligibilityAction.EMERGENCY_UNWIND


def test_emergency_trumps_defund():
    # Both Sortino decay AND drawdown trigger present
    snap = _snap(
        current_allocation_pct=0.05,
        rolling_90d_sortino=0.3,
        realized_dd_30d=0.20,
    )
    # Emergency unwind takes priority (checked first in classify_wallet)
    assert classify_wallet(snap) == EligibilityAction.EMERGENCY_UNWIND


def test_classify_batch_returns_dataframe_with_actions():
    df = pd.DataFrame([
        {
            "wallet_address": "0xa",
            "label_score": 0.9,
            "rolling_90d_sortino": 2.0,
            "n_observed_positions_90d": 30,
            "realized_dd_30d": 0.02,
            "current_allocation_pct": 0.0,
        },
        {
            "wallet_address": "0xb",
            "label_score": 0.6,
            "rolling_90d_sortino": 2.0,
            "n_observed_positions_90d": 30,
            "realized_dd_30d": 0.02,
            "current_allocation_pct": 0.0,
        },
    ])
    out = classify_batch(df)
    assert "action" in out.columns
    assert out.iloc[0]["action"] == EligibilityAction.ENTER.value
    assert out.iloc[1]["action"] == EligibilityAction.SKIP.value


def test_size_new_entry_respects_per_position_cap():
    nav = 1_000_000
    size = size_new_entry(nav=nav, current_sleeve_pct=0.0, current_wallet_pct=0.0)
    # per_position_cap default = 0.08 → 80_000
    assert size == pytest.approx(80_000)


def test_size_new_entry_respects_sleeve_cap():
    # Sleeve already at 0.39 → only 0.01 remaining capacity even though per-position cap is 0.08
    nav = 1_000_000
    size = size_new_entry(nav=nav, current_sleeve_pct=0.39, current_wallet_pct=0.0)
    assert size == pytest.approx(10_000)


def test_size_new_entry_respects_wallet_cap():
    # Wallet already has 0.10 allocation; remaining wallet capacity is 0.02
    nav = 1_000_000
    size = size_new_entry(nav=nav, current_sleeve_pct=0.20, current_wallet_pct=0.10)
    assert size == pytest.approx(20_000)


def test_size_new_entry_zero_when_sleeve_full():
    nav = 1_000_000
    size = size_new_entry(nav=nav, current_sleeve_pct=0.40, current_wallet_pct=0.0)
    assert size == 0


def test_custom_config_thresholds():
    custom = ClassifierConfig(sortino_entry_threshold=2.0)
    # 1.8 was sufficient with default 1.5; with custom 2.0 it fails
    snap = _snap(rolling_90d_sortino=1.8)
    assert classify_wallet(snap, config=custom) == EligibilityAction.SKIP
