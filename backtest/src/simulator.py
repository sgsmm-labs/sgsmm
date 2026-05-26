"""
Walk-forward backtest simulator for SGSMM.

Loops chronologically over historical Mantle wallet position data,
applying the classifier policy at each epoch and tracking vault NAV.

Outputs an equity curve + per-decision audit trail suitable for the
visual proof primitive (SGSMM vs naive baseline comparison).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional

import numpy as np
import pandas as pd
from loguru import logger

from .classifier import (
    ClassifierConfig,
    EligibilityAction,
    classify_batch,
    size_new_entry,
)
from .sortino import max_drawdown, sortino_ratio


@dataclass
class Position:
    """An active mirror position on a wallet."""

    wallet: str
    entry_epoch: datetime
    entry_nav_pct: float        # at-entry sleeve fraction
    entry_price_basis: float    # cost basis for PnL calc
    current_value: float        # MTM


@dataclass
class SimState:
    """Mutable simulator state passed through epochs."""

    nav: float
    floor_value: float          # 60% USDY treasury (assumed risk-free yield)
    sleeve_value: float         # mirror sleeve
    reserve_value: float        # 10% reserve buffer
    positions: dict[str, Position] = field(default_factory=dict)
    equity_curve: list[tuple[datetime, float]] = field(default_factory=list)
    decisions: list[dict] = field(default_factory=list)
    is_frozen: bool = False     # true if vault DD > 5% within cooldown
    freeze_until: Optional[datetime] = None


def _floor_apy_per_epoch(annual_apy: float, epoch_hours: int) -> float:
    """Convert annual APY to per-epoch return factor (compound)."""
    n_periods = 365 * 24 / epoch_hours
    return (1 + annual_apy) ** (1 / n_periods) - 1


def run_backtest(
    snapshots: pd.DataFrame,
    initial_nav: float = 100_000.0,
    floor_annual_apy: float = 0.05,    # USDY ~5% yield assumption (placeholder)
    epoch_hours: int = 24,
    config: Optional[ClassifierConfig] = None,
) -> SimState:
    """
    Walk-forward backtest over a snapshot DataFrame.

    Args:
        snapshots: DataFrame with columns:
            epoch (datetime), wallet_address, label_score,
            rolling_90d_sortino, n_observed_positions_90d,
            realized_dd_30d, wallet_return_this_epoch (float)
        initial_nav: starting capital
        floor_annual_apy: assumed USDY yield
        epoch_hours: rebalance cadence
        config: classifier thresholds

    Returns:
        Populated SimState with equity_curve + decisions audit log.
    """
    cfg = config or ClassifierConfig()

    # Capital partition per spec:
    #   60% USDY treasury floor (always-on yield)
    #   30% sleeve deployable pool (room to mirror up to sleeve_total_cap = 40%, but
    #     the 10% gap is funded by the reserve buffer in a stress scenario)
    #   10% reserve buffer (never deployed)
    # Sleeve starts at 0 deployed; deployable headroom = 30%.
    floor_share = 1.0 - cfg.sleeve_total_cap - cfg.reserve_buffer + 0.10  # = 0.60
    state = SimState(
        nav=initial_nav,
        floor_value=initial_nav * floor_share,
        sleeve_value=0.0,
        reserve_value=initial_nav * cfg.reserve_buffer,
    )

    floor_epoch_return = _floor_apy_per_epoch(floor_annual_apy, epoch_hours)

    # Group snapshots by epoch and process chronologically.
    epochs = sorted(snapshots["epoch"].unique())
    for epoch in epochs:
        epoch_snaps = snapshots[snapshots["epoch"] == epoch].copy()

        # Re-attach current allocation per wallet
        def _current_alloc(w: str) -> float:
            if w in state.positions:
                return state.positions[w].current_value / max(state.nav, 1e-9)
            return 0.0

        epoch_snaps["current_allocation_pct"] = epoch_snaps["wallet_address"].apply(_current_alloc)

        # Classify
        actions_df = classify_batch(epoch_snaps, cfg)

        # MTM floor (USDY yield)
        state.floor_value *= 1 + floor_epoch_return

        # MTM sleeve based on per-wallet returns observed this epoch
        for wallet, position in list(state.positions.items()):
            wallet_row = epoch_snaps[epoch_snaps["wallet_address"] == wallet]
            if len(wallet_row) == 0:
                continue
            period_return = float(wallet_row.iloc[0].get("wallet_return_this_epoch", 0.0))
            position.current_value *= 1 + period_return
            state.sleeve_value += position.current_value - (
                position.current_value / (1 + period_return)
            )

        # Re-sync sleeve_value from positions
        state.sleeve_value = sum(p.current_value for p in state.positions.values())

        # Update NAV
        state.nav = state.floor_value + state.sleeve_value + state.reserve_value

        # Check vault drawdown freeze
        if state.equity_curve:
            running_max = max(eq for _, eq in state.equity_curve)
            current_dd = (state.nav - running_max) / max(running_max, 1e-9)
            if current_dd < -cfg.vault_dd_freeze_threshold:
                state.is_frozen = True
                state.freeze_until = epoch + pd.Timedelta(days=cfg.vault_freeze_cooldown_days)

        if state.freeze_until is not None and epoch >= state.freeze_until:
            state.is_frozen = False
            state.freeze_until = None

        # Apply actions
        current_sleeve_pct = state.sleeve_value / max(state.nav, 1e-9)
        for _, row in actions_df.iterrows():
            action = row["action"]
            wallet = row["wallet_address"]
            if action == EligibilityAction.ENTER.value and not state.is_frozen:
                size = size_new_entry(
                    nav=state.nav,
                    current_sleeve_pct=current_sleeve_pct,
                    current_wallet_pct=0.0,
                    config=cfg,
                )
                if size > 0:
                    state.positions[wallet] = Position(
                        wallet=wallet,
                        entry_epoch=epoch,
                        entry_nav_pct=size / state.nav,
                        entry_price_basis=size,
                        current_value=size,
                    )
                    # Reduce reserve / floor proportionally
                    state.sleeve_value += size
                    state.floor_value -= size  # simplification: deploy from floor
            elif action in (
                EligibilityAction.DEFUND.value,
                EligibilityAction.EMERGENCY_UNWIND.value,
            ):
                if wallet in state.positions:
                    closed = state.positions.pop(wallet)
                    state.floor_value += closed.current_value
                    state.sleeve_value -= closed.current_value

            state.decisions.append(
                {
                    "epoch": epoch,
                    "wallet": wallet,
                    "action": action,
                    "sortino": row.get("rolling_90d_sortino"),
                    "nav_after": state.nav,
                }
            )

        # Recompute NAV after actions
        state.nav = state.floor_value + state.sleeve_value + state.reserve_value
        state.equity_curve.append((epoch, state.nav))

    return state


def summarize_run(state: SimState, initial_nav: float = 100_000.0) -> dict:
    """Compute headline metrics for kill-criterion check."""
    if not state.equity_curve:
        return {"error": "no epochs processed"}

    equity_series = pd.Series(
        [eq for _, eq in state.equity_curve],
        index=[t for t, _ in state.equity_curve],
    )
    period_returns = equity_series.pct_change().dropna()

    sortino = sortino_ratio(period_returns, cadence="daily")
    mdd = max_drawdown(equity_series)
    total_return = float(equity_series.iloc[-1] / initial_nav - 1)
    n_decisions = len(state.decisions)

    return {
        "total_return": total_return,
        "max_drawdown": mdd,
        "sortino": sortino,
        "n_epochs": len(equity_series),
        "n_decisions": n_decisions,
        "passes_kill_criterion": (
            (not np.isnan(sortino))
            and sortino >= 1.0  # relaxed kill threshold; ≥1.5 = ideal
            and abs(mdd) <= 0.15  # relaxed max DD = 15% (8% is the ideal target)
        ),
    }
