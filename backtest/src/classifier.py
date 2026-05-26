"""
Wallet eligibility classifier for SGSMM.

Implements the policy spec from docs-private/strategy-spec.md:
- label_score >= 0.7
- rolling_90d_sortino >= 1.5
- n_observed_positions_90d >= 20
- defund trigger if Sortino < 0.5 OR realized_DD_30d > 15%

Inputs are per-wallet snapshots; outputs are eligibility flags + sizing.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Optional

import pandas as pd


class EligibilityAction(str, Enum):
    """Decision actions emitted by the classifier."""
    ENTER = "ENTER"  # eligible, deploy capital
    HOLD = "HOLD"    # already mirroring, no change
    DEFUND = "DEFUND"  # unwind position (Sortino decay)
    EMERGENCY_UNWIND = "EMERGENCY_UNWIND"  # immediate (drawdown trigger)
    SKIP = "SKIP"    # not eligible


@dataclass(frozen=True)
class ClassifierConfig:
    """Configuration thresholds — match docs-private/strategy-spec.md exactly."""

    # Eligibility gate
    sortino_entry_threshold: float = 1.5
    sortino_defund_threshold: float = 0.5
    label_score_threshold: float = 0.7
    min_observed_positions_90d: int = 20

    # Defund triggers
    realized_dd_30d_threshold: float = 0.15  # > 15% triggers emergency unwind
    sortino_decay_epochs: int = 3            # unwind linearly over this many epochs

    # Vault-level safety
    vault_dd_freeze_threshold: float = 0.05  # > 5% vault DD freezes new entries
    vault_freeze_cooldown_days: int = 7

    # Sizing caps (fractions of NAV)
    per_position_cap: float = 0.08
    per_wallet_cap: float = 0.12
    sleeve_total_cap: float = 0.40
    reserve_buffer: float = 0.10


@dataclass(frozen=True)
class WalletSnapshot:
    """Per-wallet observation at one decision epoch."""

    wallet_address: str
    label_score: float                  # from Nansen / Arkham / own classifier
    rolling_90d_sortino: float          # from Sortino calculator
    n_observed_positions_90d: int       # sample-size guard
    realized_dd_30d: float              # >= 0; expressed as positive fraction
    current_allocation_pct: float       # fraction of NAV already mirrored to this wallet
    epochs_under_decay: int = 0         # for linear-defund tracking


def classify_wallet(
    snapshot: WalletSnapshot,
    config: Optional[ClassifierConfig] = None,
) -> EligibilityAction:
    """
    Apply SGSMM eligibility policy to a single wallet snapshot.

    Returns the EligibilityAction the agent should take this epoch.
    Order of checks matches the policy spec (emergency triggers checked first).
    """
    cfg = config or ClassifierConfig()

    # 1. Emergency unwind: realized drawdown over 30 days
    if snapshot.current_allocation_pct > 0 and snapshot.realized_dd_30d > cfg.realized_dd_30d_threshold:
        return EligibilityAction.EMERGENCY_UNWIND

    # 2. Sortino decay defund (linear over multiple epochs)
    if snapshot.current_allocation_pct > 0 and snapshot.rolling_90d_sortino < cfg.sortino_defund_threshold:
        return EligibilityAction.DEFUND

    # 3. Eligibility for new entry
    if snapshot.current_allocation_pct == 0:
        meets_label = snapshot.label_score >= cfg.label_score_threshold
        meets_sortino = snapshot.rolling_90d_sortino >= cfg.sortino_entry_threshold
        meets_observations = snapshot.n_observed_positions_90d >= cfg.min_observed_positions_90d
        if meets_label and meets_sortino and meets_observations:
            return EligibilityAction.ENTER
        return EligibilityAction.SKIP

    # 4. Already mirroring and still eligible — hold
    return EligibilityAction.HOLD


def classify_batch(
    snapshots: pd.DataFrame,
    config: Optional[ClassifierConfig] = None,
) -> pd.DataFrame:
    """
    Vectorized classifier over a batch of wallet snapshots.

    Expects a DataFrame with columns matching WalletSnapshot fields.
    Returns the same DataFrame with an added "action" column.
    """
    cfg = config or ClassifierConfig()
    results = []
    for row in snapshots.itertuples(index=False):
        snap = WalletSnapshot(
            wallet_address=row.wallet_address,
            label_score=row.label_score,
            rolling_90d_sortino=row.rolling_90d_sortino,
            n_observed_positions_90d=int(row.n_observed_positions_90d),
            realized_dd_30d=row.realized_dd_30d,
            current_allocation_pct=row.current_allocation_pct,
            epochs_under_decay=int(getattr(row, "epochs_under_decay", 0)),
        )
        results.append(classify_wallet(snap, cfg).value)
    out = snapshots.copy()
    out["action"] = results
    return out


def size_new_entry(
    nav: float,
    current_sleeve_pct: float,
    current_wallet_pct: float,
    config: Optional[ClassifierConfig] = None,
) -> float:
    """
    Compute size (in NAV units) for a new ENTER action.

    Capped by:
    - per-position cap (max 8% of NAV)
    - remaining per-wallet capacity (max 12% of NAV)
    - remaining sleeve capacity (max 40% of NAV)
    """
    cfg = config or ClassifierConfig()

    available_wallet = max(cfg.per_wallet_cap - current_wallet_pct, 0.0)
    available_sleeve = max(cfg.sleeve_total_cap - current_sleeve_pct, 0.0)
    target_pct = min(cfg.per_position_cap, available_wallet, available_sleeve)

    return nav * target_pct
