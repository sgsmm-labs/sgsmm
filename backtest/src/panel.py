"""
Classifier-panel assembler for SGSMM (Path B).

Turns the per-(wallet, day) PnL stream from `pnl.reconstruct_pnl` into the exact
panel that `simulator.run_backtest` and `classifier.classify_batch` consume:

    epoch, wallet_address, label_score, rolling_90d_sortino,
    n_observed_positions_90d, realized_dd_30d, wallet_return_this_epoch

This is the last hop of the real-data pipeline:

    dune_source.load_trades  ->  pnl.reconstruct_pnl  ->  panel.build_panel
                                                              |
                                                      simulator.run_backtest

Rolling features are computed per wallet over its daily return series:
  - rolling_90d_sortino: downside-risk-adjusted return (Sortino, daily cadence).
  - n_observed_positions_90d: trailing-90d swap count (the sample-size gate).
  - realized_dd_30d: trailing-30d max drawdown of the wallet's equity index,
    expressed as a positive fraction (the emergency-unwind trigger).

`label_score` is a P1 pass-through (1.0 = "no external opinion"), so the Sortino
and observation gates are the binding filters. A Nansen/ML label plugs in at P2
by passing `label_scores={wallet: score}`.
"""

from __future__ import annotations

import pandas as pd
from loguru import logger

from .pnl import reconstruct_pnl
from .sortino import max_drawdown, sortino_ratio

PANEL_COLUMNS = [
    "epoch",
    "wallet_address",
    "label_score",
    "rolling_90d_sortino",
    "n_observed_positions_90d",
    "realized_dd_30d",
    "wallet_return_this_epoch",
]


def _rolling_sortino(returns: pd.Series, window_days: int, min_obs: int) -> pd.Series:
    """Trailing-window Sortino over a daily return series (positional window)."""
    return returns.rolling(window=window_days, min_periods=min_obs).apply(
        lambda w: sortino_ratio(pd.Series(w), cadence="daily", min_observations=min_obs),
        raw=False,
    )


def _rolling_dd(returns: pd.Series, window_days: int) -> pd.Series:
    """
    Trailing-window max drawdown of the equity index built from `returns`,
    returned as a positive fraction (0.12 == a 12% drawdown).
    """
    equity = (1.0 + returns.fillna(0.0)).cumprod()
    dd = equity.rolling(window=window_days, min_periods=2).apply(max_drawdown, raw=False)
    return (-dd).clip(lower=0.0)


def build_panel(
    pnl_panel: pd.DataFrame,
    label_scores: dict[str, float] | None = None,
    sortino_window_days: int = 90,
    dd_window_days: int = 30,
    obs_window_days: int = 90,
    min_obs_for_sortino: int = 10,
    default_label_score: float = 1.0,
) -> pd.DataFrame:
    """
    Assemble the simulator/classifier panel from a reconstructed PnL panel.

    Args:
        pnl_panel: output of `pnl.reconstruct_pnl` (wallet, day, daily_return,
            realized_pnl_usd, risky_value_end, n_trades).
        label_scores: optional {wallet -> label_score} (Nansen/ML at P2). Wallets
            absent from the mapping get `default_label_score`.
        sortino_window_days / dd_window_days / obs_window_days: rolling windows.
        min_obs_for_sortino: minimum daily returns in-window before Sortino is
            defined (NaN below this; classifier then treats the wallet as SKIP).
        default_label_score: P1 pass-through label for unscored wallets.

    Returns:
        DataFrame with PANEL_COLUMNS, sorted by (epoch, wallet_address).
    """
    if pnl_panel.empty:
        return pd.DataFrame(columns=PANEL_COLUMNS)

    label_scores = label_scores or {}
    pnl_panel = pnl_panel.sort_values(["wallet", "day"])

    frames: list[pd.DataFrame] = []
    for wallet, sub in pnl_panel.groupby("wallet", sort=False):
        sub = sub.sort_values("day")
        returns = sub.set_index("day")["daily_return"]
        n_trades = sub.set_index("day")["n_trades"]

        rolling_sortino = _rolling_sortino(returns, sortino_window_days, min_obs_for_sortino)
        rolling_obs = n_trades.rolling(window=obs_window_days, min_periods=1).sum()
        rolling_dd_30 = _rolling_dd(returns, dd_window_days)

        frame = pd.DataFrame(
            {
                "epoch": sub["day"].to_numpy(),
                "wallet_address": wallet,
                "label_score": float(label_scores.get(wallet, default_label_score)),
                "rolling_90d_sortino": rolling_sortino.to_numpy(),
                "n_observed_positions_90d": rolling_obs.to_numpy(),
                "realized_dd_30d": rolling_dd_30.to_numpy(),
                "wallet_return_this_epoch": returns.to_numpy(),
            }
        )
        frames.append(frame)

    panel = pd.concat(frames, ignore_index=True)
    panel["rolling_90d_sortino"] = panel["rolling_90d_sortino"].fillna(0.0)
    panel["n_observed_positions_90d"] = (
        panel["n_observed_positions_90d"].fillna(0).astype(int)
    )
    panel["realized_dd_30d"] = panel["realized_dd_30d"].fillna(0.0)
    panel["wallet_return_this_epoch"] = panel["wallet_return_this_epoch"].fillna(0.0)
    panel = panel.sort_values(["epoch", "wallet_address"]).reset_index(drop=True)

    logger.info(
        "assembled classifier panel: {} rows / {} wallets / {} epochs",
        len(panel),
        panel["wallet_address"].nunique(),
        panel["epoch"].nunique(),
    )
    return panel[PANEL_COLUMNS]


def build_panel_from_trades(
    trades: pd.DataFrame,
    label_scores: dict[str, float] | None = None,
    **kwargs: object,
) -> pd.DataFrame:
    """Convenience: canonical trades -> reconstructed PnL -> classifier panel."""
    pnl_panel = reconstruct_pnl(trades)
    return build_panel(pnl_panel, label_scores=label_scores, **kwargs)  # type: ignore[arg-type]
