"""
Sortino ratio computation for SGSMM eligibility gating.

Reference policy (see docs-private/strategy-spec.md):
- Rolling 90d window
- MAR (Minimum Acceptable Return) = 0
- Annualize by sqrt(8760) when working with hourly returns
- Require minimum 20 observations for statistical significance

The Sortino ratio differs from Sharpe by penalizing only downside volatility:

    Sortino = (mean_return - MAR) / downside_deviation
    downside_deviation = sqrt(mean(min(0, return - MAR)^2))

For SGSMM the input series is per-wallet hourly return on tracked NAV.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

# Annualization factors for common cadences
ANNUALIZATION = {
    "hourly": np.sqrt(24 * 365),
    "daily": np.sqrt(365),
    "weekly": np.sqrt(52),
}


def downside_deviation(returns: pd.Series, mar: float = 0.0) -> float:
    """
    Downside semi-deviation: square-root of mean of squared *negative* deviations from MAR.

    Returns NaN if no observations are below MAR (no downside captured yet).
    """
    if len(returns) == 0:
        return float("nan")
    deviations = returns - mar
    negative_deviations = np.minimum(deviations, 0.0)
    sq = negative_deviations**2
    mean_sq = sq.mean()
    if mean_sq == 0:
        return float("nan")  # all returns >= MAR, downside undefined
    return float(np.sqrt(mean_sq))


def sortino_ratio(
    returns: pd.Series,
    mar: float = 0.0,
    cadence: str = "hourly",
    min_observations: int = 20,
) -> float:
    """
    Compute Sortino ratio for a return series.

    Args:
        returns: pd.Series of period returns (e.g., hourly returns indexed by timestamp)
        mar: minimum acceptable return per period (default 0)
        cadence: "hourly", "daily", or "weekly" — sets annualization factor
        min_observations: returns NaN if fewer than this many observations (sample size guard)

    Returns:
        Annualized Sortino ratio (float). NaN if insufficient observations or zero downside.
    """
    if len(returns) < min_observations:
        return float("nan")

    excess = returns.mean() - mar
    dd = downside_deviation(returns, mar=mar)
    if np.isnan(dd) or dd == 0:
        return float("nan")

    annualization = ANNUALIZATION.get(cadence)
    if annualization is None:
        raise ValueError(f"Unknown cadence {cadence!r}; expected one of {list(ANNUALIZATION)}")

    return float(excess / dd * annualization)


def rolling_sortino(
    returns: pd.Series,
    window_periods: int,
    mar: float = 0.0,
    cadence: str = "hourly",
    min_observations: int = 20,
) -> pd.Series:
    """
    Rolling Sortino ratio across a return series.

    Args:
        returns: hourly (or chosen-cadence) returns indexed chronologically
        window_periods: window length in number of periods (e.g. 90 days * 24h = 2160 for hourly)
        mar: minimum acceptable return
        cadence: annualization cadence
        min_observations: NaN result if window has fewer non-null returns than this
    """
    return returns.rolling(window=window_periods, min_periods=min_observations).apply(
        lambda w: sortino_ratio(
            pd.Series(w), mar=mar, cadence=cadence, min_observations=min_observations
        ),
        raw=False,
    )


def max_drawdown(equity: pd.Series) -> float:
    """
    Maximum drawdown of an equity curve.

    Returns the most negative drawdown observed (e.g., -0.12 for 12% drawdown).
    """
    if len(equity) == 0:
        return 0.0
    running_max = equity.cummax()
    drawdown = (equity - running_max) / running_max
    return float(drawdown.min())


def calmar_ratio(equity: pd.Series, periods_per_year: int = 8760) -> float:
    """
    Calmar ratio = annualized return / |max drawdown|.

    Note: Calmar's denominator is monotonically non-decreasing, so a single flash crash
    permanently degrades the metric. SGSMM uses Calmar only as a sanity-check, not a gate.
    """
    if len(equity) < 2:
        return float("nan")
    total_return = equity.iloc[-1] / equity.iloc[0] - 1
    n_periods = len(equity)
    annualized = (1 + total_return) ** (periods_per_year / n_periods) - 1
    mdd = abs(max_drawdown(equity))
    if mdd == 0:
        return float("nan")
    return float(annualized / mdd)
