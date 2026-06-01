"""
Dashboard data generator — derives frontend/public/data/*.json from the REAL
backtest artifacts so the Next.js dashboard renders verifiable Mantle data.

Inputs (real Mantle DEX trades -> FIFO PnL -> classifier panel):
    backtest/results/panel_real.csv      per-(wallet, epoch) classifier stats
    backtest/results/equity_real.csv     vault NAV per epoch (26 daily epochs)
    backtest/results/summary_real.json   headline return / drawdown / sortino

Outputs (consumed by frontend/src/lib/data.ts):
    public/data/leaderboard.json   full 363-wallet universe, latest epoch each
    public/data/decisions.json     decision change-log (binding transitions)
    public/data/equity.json        NAV vs flat $100k principal reference
    public/data/vault.json         current vault state

Verdict vocabulary note: the backtest/bot emit ENTER/SKIP/DEFUND/EMERGENCY_UNWIND.
The leaderboard view uses the dashboard's 4-bucket Verdict (MIRRORED/WATCHING/
SKIPPED/DEFUNDED) derived purely from the two columns the page shows (Sortino +
30d drawdown), so the badge is self-consistent with the on-page gate legend.
The decision feed keeps the native action vocabulary (it matches DecisionAction).

Run from repo root with a pandas-equipped interpreter, e.g. the agent venv:
    agent/.venv/Scripts/python.exe frontend/scripts/build_data.py
"""

from __future__ import annotations

import json
from pathlib import Path

import pandas as pd

# --- SGSMM classifier thresholds (mirror backtest/src/classifier.py) ----------
SORTINO_ENTRY_THRESHOLD = 1.5
SORTINO_DEFUND_THRESHOLD = 0.5
LABEL_SCORE_THRESHOLD = 0.7
MIN_OBSERVED_POSITIONS_90D = 20
REALIZED_DD_30D_THRESHOLD = 0.15

# Sleeve pool = 30% of NAV (matches vault.sleevePct), equal-weighted across the
# wallets actively cleared to ENTER in a given epoch. Expressed in bps of NAV.
SLEEVE_POOL_BPS = 3000

# Honest reference line: the $100k principal deposited at inception.
PRINCIPAL = 100_000

_FRONTEND_DIR = Path(__file__).resolve().parents[1]
_REPO_ROOT = _FRONTEND_DIR.parent
PANEL_CSV = _REPO_ROOT / "backtest" / "results" / "panel_real.csv"
EQUITY_CSV = _REPO_ROOT / "backtest" / "results" / "equity_real.csv"
SUMMARY_JSON = _REPO_ROOT / "backtest" / "results" / "summary_real.json"
OUT_DIR = _FRONTEND_DIR / "public" / "data"

DECISION_FEED_CAP = 120


def real_action(label: float, sortino: float, n_obs: int, dd: float) -> str:
    """Native SGSMM action (emergency triggers first; mirrors compute_verdict)."""
    if dd >= REALIZED_DD_30D_THRESHOLD:
        return "EMERGENCY_UNWIND"
    if sortino < SORTINO_DEFUND_THRESHOLD:
        return "DEFUND"
    if (
        label >= LABEL_SCORE_THRESHOLD
        and sortino >= SORTINO_ENTRY_THRESHOLD
        and n_obs >= MIN_OBSERVED_POSITIONS_90D
    ):
        return "ENTER"
    return "SKIP"


def front_verdict(sortino: float, dd: float) -> str:
    """
    Dashboard 4-bucket verdict, a pure function of the two columns the
    leaderboard renders (Sortino + 30d drawdown). A drawdown breach forces
    DEFUNDED regardless of Sortino, matching the risk gate.
    """
    if dd >= REALIZED_DD_30D_THRESHOLD:
        return "DEFUNDED"
    if sortino >= SORTINO_ENTRY_THRESHOLD:
        return "MIRRORED"
    if sortino >= 1.0:
        return "WATCHING"
    if sortino >= SORTINO_DEFUND_THRESHOLD:
        return "SKIPPED"
    return "DEFUNDED"


def main() -> None:
    panel = pd.read_csv(PANEL_CSV)
    equity = pd.read_csv(EQUITY_CSV)
    summary = json.loads(SUMMARY_JSON.read_text(encoding="utf-8"))

    # Map the timestamp epochs to compact integer indices 1..N for the UI.
    epochs = sorted(panel["epoch"].unique())
    epoch_idx = {e: i + 1 for i, e in enumerate(epochs)}
    panel = panel.assign(epoch_i=panel["epoch"].map(epoch_idx))

    nav_by_epoch = {i + 1: round(float(v), 2) for i, v in enumerate(equity["nav"])}
    final_nav = nav_by_epoch[max(nav_by_epoch)]

    # ---- leaderboard.json : full universe, latest epoch per wallet ----------
    latest = (
        panel.sort_values(["wallet_address", "epoch_i"])
        .groupby("wallet_address", as_index=False)
        .tail(1)
    )
    leaderboard = []
    for r in latest.itertuples(index=False):
        s = float(r.rolling_90d_sortino)
        dd = float(r.realized_dd_30d)
        leaderboard.append(
            {
                "address": str(r.wallet_address),
                "sortino": round(s, 2),
                "dd30d": round(-dd * 100.0, 1),
                "observations": int(r.n_observed_positions_90d),
                "verdict": front_verdict(s, dd),
            }
        )
    leaderboard.sort(key=lambda w: w["sortino"], reverse=True)
    mirrored = sum(1 for w in leaderboard if w["verdict"] == "MIRRORED")

    # ---- decisions.json : binding-action change-log across epochs -----------
    # Active ENTER count per epoch drives equal-weight sleeve sizing.
    active_enter_per_epoch: dict[int, int] = {}
    for r in panel.itertuples(index=False):
        if (
            real_action(
                float(r.label_score),
                float(r.rolling_90d_sortino),
                int(r.n_observed_positions_90d),
                float(r.realized_dd_30d),
            )
            == "ENTER"
        ):
            active_enter_per_epoch[int(r.epoch_i)] = (
                active_enter_per_epoch.get(int(r.epoch_i), 0) + 1
            )

    events = []
    prev_action: dict[str, str] = {}
    for r in panel.sort_values(["wallet_address", "epoch_i"]).itertuples(index=False):
        w = str(r.wallet_address)
        ei = int(r.epoch_i)
        s = float(r.rolling_90d_sortino)
        action = real_action(
            float(r.label_score), s, int(r.n_observed_positions_90d), float(r.realized_dd_30d)
        )
        changed = action != prev_action.get(w)
        prev_action[w] = action
        if not changed or action == "SKIP":
            continue  # log only transitions into a binding action
        sleeve = 0
        if action == "ENTER":
            k = active_enter_per_epoch.get(ei, 1) or 1
            sleeve = max(1, round(SLEEVE_POOL_BPS / k))
        events.append(
            {
                "epoch": ei,
                "wallet": w,
                "action": action,
                "sortino": round(s, 2),
                "sleevePctBps": sleeve,
                "navAfter": nav_by_epoch.get(ei, final_nav),
            }
        )
    events.sort(key=lambda e: e["epoch"], reverse=True)
    decisions = events[:DECISION_FEED_CAP]

    # ---- vault.json ----------------------------------------------------------
    vault = {
        "nav": final_nav,
        "floorPct": 60,
        "sleevePct": 30,
        "reservePct": 10,
        "activeMirrors": mirrored,
        "lastRebalance": "2025-12-26T00:00:00Z",
        "nextRebalance": "2025-12-27T00:00:00Z",
        "floorAsset": "USDY",
        "floorVenueLabel": "Lendle / Init Capital",
        "sleeveVenueLabel": "Agni / Merchant Moe",
        "cycleEpoch": len(epochs),
        "totalDecisionsLogged": int(len(panel)),
        "cumulativeReturn": round(float(summary["total_return"]) * 100.0, 2),
        # ---- Honest kill-criterion disclosure (mirror summary_real.json) -----
        # BLENDED portfolio-level Sortino across the whole 26-epoch backtest,
        # including the always-on 60% USDY floor. The floor's smooth, zero-
        # downside yield inflates this number, so it is NOT proof of alpha — it
        # is surfaced only for transparency, NOT the value the gate is judged on.
        "portfolioSortino": round(float(summary["sortino"]), 2),
        # ALPHA (strategy-only) Sortino = derived from nav-minus-floor. This is
        # the honest number the kill-criterion gate (>= 1.5) is actually judged
        # on. May be null when there is no alpha movement yet (floor-only window).
        "alphaSortino": (
            None
            if summary.get("alpha_sortino") is None or pd.isna(summary.get("alpha_sortino"))
            else round(float(summary["alpha_sortino"]), 2)
        ),
        # Count of epochs where the mirror sleeve actually held capital ("on").
        "nActiveEpochs": int(summary.get("n_active_epochs", 0)),
        # Whether the window is long enough (>= 90 epochs) to validly test a
        # 90-day-gated strategy. FALSE here => the verdict cannot be a real pass.
        "sufficientData": bool(summary.get("sufficient_data", False)),
        # Worst peak-to-trough drawdown over the window, percent (negative).
        "maxDrawdownPct": round(float(summary["max_drawdown"]) * 100.0, 1),
        # The strategy does NOT clear its own gate. Surfaced honestly in the UI.
        "passesKillCriterion": bool(summary.get("passes_kill_criterion", False)),
        "sortinoGate": SORTINO_ENTRY_THRESHOLD,
    }

    # ---- equity.json : NAV vs flat principal reference -----------------------
    equity_pts = [
        {"epoch": i + 1, "nav": round(float(v), 2), "baselineNav": PRINCIPAL}
        for i, v in enumerate(equity["nav"])
    ]

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    (OUT_DIR / "leaderboard.json").write_text(json.dumps(leaderboard, indent=2) + "\n", encoding="utf-8")
    (OUT_DIR / "decisions.json").write_text(json.dumps(decisions, indent=2) + "\n", encoding="utf-8")
    (OUT_DIR / "equity.json").write_text(json.dumps(equity_pts, indent=2) + "\n", encoding="utf-8")
    (OUT_DIR / "vault.json").write_text(json.dumps(vault, indent=2) + "\n", encoding="utf-8")

    print(f"leaderboard wallets : {len(leaderboard)}  (MIRRORED={mirrored})")
    print(f"decision events     : {len(decisions)} of {len(events)} transitions")
    print(f"equity points       : {len(equity_pts)}  final NAV={final_nav}")
    print(f"cumulative return   : {vault['cumulativeReturn']}%  decisions logged={vault['totalDecisionsLogged']}")
    print(
        f"kill-criterion      : blendedSortino={vault['portfolioSortino']} "
        f"alphaSortino={vault['alphaSortino']} (gate>={SORTINO_ENTRY_THRESHOLD}) "
        f"activeEpochs={vault['nActiveEpochs']} sufficientData={vault['sufficientData']} "
        f"maxDD={vault['maxDrawdownPct']}%  passes={vault['passesKillCriterion']}"
    )


if __name__ == "__main__":
    main()
