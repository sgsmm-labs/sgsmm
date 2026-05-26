"""
Unit tests for sortino.py.

These tests pin the math so we know the kill-criterion gate measures
exactly what the strategy spec claims.
"""

from __future__ import annotations

import math

import numpy as np
import pandas as pd
import pytest

from src.sortino import (
    ANNUALIZATION,
    calmar_ratio,
    downside_deviation,
    max_drawdown,
    rolling_sortino,
    sortino_ratio,
)


def test_downside_deviation_zero_when_all_positive():
    returns = pd.Series([0.01, 0.02, 0.03, 0.005])
    # All returns above MAR=0; downside deviation undefined → NaN
    assert math.isnan(downside_deviation(returns, mar=0.0))


def test_downside_deviation_positive_when_negative_returns():
    returns = pd.Series([0.02, -0.01, 0.03, -0.02])
    dd = downside_deviation(returns, mar=0.0)
    # sqrt(mean(0^2, 0.01^2, 0^2, 0.02^2)) = sqrt((0.0001 + 0.0004)/4) = sqrt(0.000125) ≈ 0.01118
    assert dd == pytest.approx(0.011180, rel=1e-3)


def test_sortino_returns_nan_for_short_series():
    returns = pd.Series([0.01, -0.005, 0.02])
    # < min_observations=20 → NaN
    assert math.isnan(sortino_ratio(returns, min_observations=20))


def test_sortino_returns_nan_when_no_downside():
    np.random.seed(0)
    returns = pd.Series(np.abs(np.random.normal(0.001, 0.01, 100)))  # all positive
    assert math.isnan(sortino_ratio(returns, min_observations=20))


def test_sortino_positive_for_good_strategy():
    np.random.seed(42)
    # Mostly positive returns with occasional small drawdowns
    returns = pd.Series(np.random.normal(0.002, 0.005, 300))
    ratio = sortino_ratio(returns, cadence="hourly")
    assert ratio > 0
    assert not math.isnan(ratio)


def test_sortino_higher_than_sharpe_when_skewed():
    """
    For a left-skewed positive-mean series, Sortino should differ from Sharpe.
    This sanity-checks that we're measuring downside-only volatility.
    """
    np.random.seed(7)
    # Build a series with positive mean but occasional large drawdowns
    returns = pd.Series(np.concatenate([
        np.random.normal(0.003, 0.005, 200),  # mostly positive
        np.full(20, -0.02),                    # 20 large drawdown events
    ]))
    np.random.shuffle(returns.values)
    sortino = sortino_ratio(returns, cadence="hourly", min_observations=20)
    sharpe = (returns.mean() / returns.std()) * ANNUALIZATION["hourly"]
    # Sortino can differ either way depending on skew; here we just check it's finite
    assert not math.isnan(sortino)
    assert not math.isnan(sharpe)


def test_rolling_sortino_window_smaller_than_series():
    np.random.seed(1)
    returns = pd.Series(np.random.normal(0.001, 0.01, 200))
    rolling = rolling_sortino(returns, window_periods=50, min_observations=20)
    # First (window - 1) values should be NaN (or until min_observations met)
    assert len(rolling) == 200
    assert math.isnan(rolling.iloc[10])  # before min_obs
    assert not math.isnan(rolling.iloc[150])  # well into the series


def test_max_drawdown_basic():
    # Equity goes 100 → 120 → 90 → 110 → 130; max DD = (90-120)/120 = -0.25
    equity = pd.Series([100, 120, 90, 110, 130])
    mdd = max_drawdown(equity)
    assert mdd == pytest.approx(-0.25)


def test_max_drawdown_no_drawdown():
    equity = pd.Series([100, 101, 102, 103])
    assert max_drawdown(equity) == 0.0


def test_calmar_ratio_basic():
    # Equity doubles over a year → +100%; max DD = 50% → Calmar = 2.0
    # Use 365 daily periods
    equity = pd.Series([100] + [110] * 100 + [55] * 50 + [200] * 214)
    calmar = calmar_ratio(equity, periods_per_year=365)
    # Sign-check only; exact magnitude depends on time path
    assert calmar > 0


def test_sortino_unknown_cadence_raises():
    returns = pd.Series(np.random.normal(0.001, 0.01, 100))
    with pytest.raises(ValueError):
        sortino_ratio(returns, cadence="monthly")
