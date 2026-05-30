"""
Simulator invariant tests for SGSMM.

These lock in the capital-accounting invariants that a prior bug violated
(NAV dropped to 70% of initial_nav at t0 because the 30% deployable pool was
never counted into NAV, and entries were funded out of the floor).
"""

from __future__ import annotations

from datetime import datetime, timedelta

import pandas as pd

from src.classifier import ClassifierConfig
from src.simulator import run_backtest


def _panel(rows_per_epoch: list[dict], n_epochs: int = 5) -> pd.DataFrame:
    """Repeat a per-wallet row template across n_epochs daily snapshots."""
    t0 = datetime(2026, 1, 1)
    rows = []
    for i in range(n_epochs):
        epoch = t0 + timedelta(days=i)
        for r in rows_per_epoch:
            rows.append({"epoch": epoch, **r})
    return pd.DataFrame(rows)


def _ineligible_wallet(addr: str) -> dict:
    """A wallet the gate must reject (label below threshold)."""
    return {
        "wallet_address": addr,
        "label_score": 0.10,
        "rolling_90d_sortino": 0.9,
        "n_observed_positions_90d": 30,
        "realized_dd_30d": 0.0,
        "wallet_return_this_epoch": 0.05,  # would be very profitable IF mirrored
    }


def _eligible_wallet(addr: str) -> dict:
    """A wallet that passes every gate."""
    return {
        "wallet_address": addr,
        "label_score": 0.90,
        "rolling_90d_sortino": 2.0,
        "n_observed_positions_90d": 30,
        "realized_dd_30d": 0.0,
        "wallet_return_this_epoch": 0.01,
    }


def test_nav_starts_at_initial_nav_with_no_yield():
    """With floor yield off and no eligible wallets, NAV never leaves initial_nav."""
    panel = _panel([_ineligible_wallet("0xaaa")])
    state = run_backtest(panel, initial_nav=100_000.0, floor_annual_apy=0.0)
    navs = [nav for _, nav in state.equity_curve]
    assert navs, "no epochs processed"
    for nav in navs:
        assert abs(nav - 100_000.0) < 1e-6, f"NAV drifted to {nav} with no yield/entries"


def test_ineligible_profitable_wallet_is_never_mirrored():
    """A high-return wallet below the label gate must contribute nothing to NAV."""
    panel = _panel([_ineligible_wallet("0xaaa")])
    state = run_backtest(panel, initial_nav=100_000.0, floor_annual_apy=0.0)
    assert state.sleeve_value == 0.0
    assert "0xaaa" not in state.positions


def test_capital_conservation_partitions_sum_to_nav():
    """floor + deployable + sleeve + reserve must always equal NAV."""
    panel = _panel([_eligible_wallet("0xbbb"), _ineligible_wallet("0xccc")])
    state = run_backtest(panel, initial_nav=100_000.0, floor_annual_apy=0.05)
    total = (
        state.floor_value
        + state.deployable_value
        + state.sleeve_value
        + state.reserve_value
    )
    assert abs(total - state.nav) < 1e-6


def test_eligible_wallet_gets_deployed_from_pool_not_floor():
    """ENTER must draw down the deployable pool and grow the sleeve, leaving the
    USDY floor (plus its yield) intact."""
    cfg = ClassifierConfig()
    panel = _panel([_eligible_wallet("0xbbb")], n_epochs=2)
    state = run_backtest(panel, initial_nav=100_000.0, floor_annual_apy=0.0, config=cfg)
    assert state.sleeve_value > 0.0, "eligible wallet was not mirrored"
    # Floor untouched by deployment (no yield in this test) → still ~60k.
    assert abs(state.floor_value - 60_000.0) < 1.0
    # Sleeve deployed within the per-position cap (8% of NAV).
    assert state.sleeve_value <= 100_000.0 * cfg.per_position_cap * 1.5
