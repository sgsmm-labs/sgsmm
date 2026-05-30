"""
FIFO cost-basis PnL + mark-to-market return engine for SGSMM (Path B).

Takes the canonical Mantle DEX-trade frame produced by `dune_source.load_trades`
and reconstructs, per wallet, a daily mark-to-market return series plus realized
PnL. This is the bridge between raw on-chain swaps and the Sortino-gated
classifier panel: the classifier needs a per-wallet daily return stream, and a
swap log is not that — it is a sequence of token<->token conversions. This module
turns the second into the first.

Method (industry-standard, mirrors Zerion/Nansen position accounting):

  1. Token prices. Each swap implies a USD unit price for both legs
     (`amount_usd / amount`). Aggregated per (token, day) as a volume-weighted
     average, this yields a daily price panel with no external oracle needed.

  2. FIFO lots. Per (wallet, risky-token) we keep a FIFO queue of cost lots.
     Buying a risky token pushes a lot at its USD unit cost; selling pops lots
     oldest-first and realizes PnL = proceeds - matched cost. Disposing more than
     was ever acquired in-window (pre-window or bridged-in inventory) realizes
     zero on the uncovered quantity rather than phantom gains.

  3. Mark-to-market return. We value each wallet's RISKY holdings every day across
     its active range (holdings carried forward over no-trade days) and take a
     Modified-Dietz daily return so that capital arriving (stable -> risky) or
     leaving (risky -> stable) is treated as a flow, not as performance. Stable
     legs are cash; risky<->risky swaps are value-conserving internal rebalances.
     The result is the price-performance return a mirror of the wallet would earn
     that day — exactly what `simulator.run_backtest` multiplies the sleeve by.

Stablecoins are treated as cash (the numeraire), so a wallet sitting in USDC has
a flat return, and only its at-risk token exposure drives Sortino.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field

import numpy as np
import pandas as pd
from loguru import logger

# Symbols treated as USD cash (the numeraire). Matched case-insensitively against
# the trade's token symbol. Kept explicit to avoid mislabeling e.g. a governance
# token whose name merely contains "USD". `dex.trades` symbols are upper-case.
STABLE_SYMBOLS: frozenset[str] = frozenset(
    {
        "USDC",
        "USDC.E",
        "USDT",
        "USDT.E",
        "USDE",
        "SUSDE",
        "USDY",
        "MUSD",
        "DAI",
        "FRAX",
        "LUSD",
        "TUSD",
        "USDV",
        "USD0",
        "GUSD",
        "FDUSD",
        "USDB",
        "CUSD",
        "AUSD",
    }
)

PANEL_COLUMNS = [
    "wallet",
    "day",
    "daily_return",
    "realized_pnl_usd",
    "risky_value_end",
    "n_trades",
]


def is_stable(symbol: object) -> bool:
    """True if a token symbol denotes a USD stablecoin (treated as cash)."""
    if symbol is None:
        return False
    return str(symbol).strip().upper() in STABLE_SYMBOLS


@dataclass
class _Lot:
    """One FIFO cost lot: a quantity acquired at a USD unit cost."""

    qty: float
    unit_cost_usd: float


@dataclass
class _Book:
    """Per-wallet running state while replaying trades chronologically."""

    # risky token address -> FIFO queue of cost lots
    lots: dict[str, deque[_Lot]] = field(default_factory=dict)
    # risky token address -> current held quantity (sum of lot qtys)
    holdings: dict[str, float] = field(default_factory=dict)

    def add_lot(self, token: str, qty: float, unit_cost_usd: float) -> None:
        self.lots.setdefault(token, deque()).append(_Lot(qty, unit_cost_usd))
        self.holdings[token] = self.holdings.get(token, 0.0) + qty

    def dispose(self, token: str, qty: float, proceeds_usd: float) -> float:
        """
        Remove `qty` of `token` FIFO and return realized PnL against matched cost.

        `proceeds_usd` is the USD value received for the whole disposed quantity.
        Uncovered quantity (no remaining lots) realizes zero PnL — its implied
        cost basis is set equal to its share of proceeds, never phantom gain.
        """
        queue = self.lots.get(token)
        self.holdings[token] = self.holdings.get(token, 0.0) - qty
        if not queue:
            return 0.0  # selling inventory we never acquired in-window
        unit_proceeds = proceeds_usd / qty if qty > 0 else 0.0
        remaining = qty
        matched_cost = 0.0
        covered = 0.0
        while remaining > 1e-18 and queue:
            lot = queue[0]
            take = min(lot.qty, remaining)
            matched_cost += take * lot.unit_cost_usd
            covered += take
            lot.qty -= take
            remaining -= take
            if lot.qty <= 1e-18:
                queue.popleft()
        # Realize only over the covered portion; uncovered portion is PnL-neutral.
        realized = covered * unit_proceeds - matched_cost
        return float(realized)

    def snapshot(self) -> dict[str, float]:
        """Copy of current non-dust holdings (token address -> qty)."""
        return {t: q for t, q in self.holdings.items() if q > 1e-18}


def build_daily_prices(trades: pd.DataFrame) -> dict[str, pd.Series]:
    """
    Volume-weighted daily USD price per token address.

    Explodes each swap into its two legs (bought + sold), then for every
    (token_address, day) computes sum(amount_usd) / sum(amount). Returns a dict
    token_address -> Series(price indexed by day, sorted) for as-of lookups.
    """
    bought = pd.DataFrame(
        {
            "token": trades["token_bought_address"],
            "day": trades["day"],
            "amt": pd.to_numeric(trades["amt_bought"], errors="coerce"),
            "usd": pd.to_numeric(trades["amount_usd"], errors="coerce"),
        }
    )
    sold = pd.DataFrame(
        {
            "token": trades["token_sold_address"],
            "day": trades["day"],
            "amt": pd.to_numeric(trades["amt_sold"], errors="coerce"),
            "usd": pd.to_numeric(trades["amount_usd"], errors="coerce"),
        }
    )
    legs = pd.concat([bought, sold], ignore_index=True)
    legs = legs[(legs["amt"] > 0) & (legs["usd"] > 0) & legs["token"].notna()]

    grouped = legs.groupby(["token", "day"], sort=True).agg(
        usd=("usd", "sum"), amt=("amt", "sum")
    )
    grouped["price"] = grouped["usd"] / grouped["amt"]

    prices: dict[str, pd.Series] = {}
    for token, sub in grouped.reset_index().groupby("token", sort=False):
        prices[token] = sub.set_index("day")["price"].sort_index()
    logger.info("built daily VWAP price panel for {} tokens", len(prices))
    return prices


def _price_asof(series: pd.Series | None, day: pd.Timestamp) -> float:
    """Last known price at or before `day`; NaN if the token has no prior print."""
    if series is None or series.empty:
        return float("nan")
    val = series.asof(day)
    return float(val) if val is not None and not pd.isna(val) else float("nan")


def _value_holdings(
    holdings: dict[str, float], prices: dict[str, pd.Series], day: pd.Timestamp
) -> float:
    """USD value of risky holdings at the given day's (as-of) prices."""
    total = 0.0
    for tok, qty in holdings.items():
        if qty <= 1e-18:
            continue
        px = _price_asof(prices.get(tok), day)
        if not np.isnan(px):
            total += qty * px
    return total


def reconstruct_pnl(
    trades: pd.DataFrame,
    end_day: pd.Timestamp | None = None,
    min_capital_base: float = 10.0,
    return_floor: float = -0.95,
    return_cap: float = 1.0,
) -> pd.DataFrame:
    """
    Replay every wallet's swaps and emit a per-(wallet, day) panel.

    Returns a DataFrame with columns:
        wallet, day, daily_return, realized_pnl_usd, risky_value_end, n_trades

    - daily_return: Modified-Dietz MTM return on risky holdings (flows = stable
      legs), i.e. the return a mirror of this wallet earns that day. Computed on
      every day in the wallet's active range, including no-trade days (holdings
      carried forward), so buy-and-hold performance is captured. Hardened for
      real on-chain data: the capital base is floored at `min_capital_base` USD
      (dust denominators otherwise produce astronomically large returns) and the
      result is winsorized to `[return_floor, return_cap]` so a single mispriced
      thin-token print can't blow up the sleeve — and the return can never be
      <= -1, which would drive a mirrored position value negative.

    Args:
        end_day: last day to mark still-open positions to (default global max).
        min_capital_base: minimum USD risk-capital base to score a return on;
            below it the day's return is 0.0 (too little at risk to be signal).
        return_floor / return_cap: winsorization bounds for the daily return.
    - realized_pnl_usd: FIFO realized PnL booked that day.
    - risky_value_end: USD value of risky holdings at day close.
    - n_trades: swaps executed that day (sample-size signal for the gate).

    A wallet still holding risky inventory after its last trade keeps accruing MTM
    rows through `end_day` (defaults to the global last trade day); a wallet that
    has fully exited to cash stops emitting once flat, to keep the panel lean.
    """
    if trades.empty:
        return pd.DataFrame(columns=PANEL_COLUMNS)

    prices = build_daily_prices(trades)
    trades = trades.sort_values("block_time")
    if end_day is None:
        end_day = pd.Timestamp(trades["day"].max())

    out_rows: list[dict] = []
    n_wallets = 0
    for wallet, wtrades in trades.groupby("wallet", sort=False):
        n_wallets += 1
        book = _Book()

        # Per-trade-day aggregates and an end-of-day holdings snapshot.
        realized_by_day: dict[pd.Timestamp, float] = {}
        flow_by_day: dict[pd.Timestamp, float] = {}
        ntrades_by_day: dict[pd.Timestamp, int] = {}
        snapshot_by_day: dict[pd.Timestamp, dict[str, float]] = {}

        for row in wtrades.itertuples(index=False):
            day = row.day
            amount_usd = float(row.amount_usd) if not pd.isna(row.amount_usd) else 0.0
            sold_tok = row.token_sold_address
            bought_tok = row.token_bought_address
            amt_sold = float(row.amt_sold) if not pd.isna(row.amt_sold) else 0.0
            amt_bought = float(row.amt_bought) if not pd.isna(row.amt_bought) else 0.0
            sold_is_stable = is_stable(row.token_sold)
            bought_is_stable = is_stable(row.token_bought)

            ntrades_by_day[day] = ntrades_by_day.get(day, 0) + 1

            # Sold leg: dispose risky inventory and realize FIFO PnL.
            if not sold_is_stable and amt_sold > 0 and isinstance(sold_tok, str):
                realized = book.dispose(sold_tok, amt_sold, amount_usd)
                realized_by_day[day] = realized_by_day.get(day, 0.0) + realized

            # Bought leg: open a new risky lot at its USD unit cost.
            if not bought_is_stable and amt_bought > 0 and isinstance(bought_tok, str):
                book.add_lot(bought_tok, amt_bought, amount_usd / amt_bought)

            # Modified-Dietz flows: stable<->risky moves capital across the risky
            # book boundary; risky<->risky and stable<->stable do not.
            if sold_is_stable and not bought_is_stable:
                flow_by_day[day] = flow_by_day.get(day, 0.0) + amount_usd   # inflow
            elif not sold_is_stable and bought_is_stable:
                flow_by_day[day] = flow_by_day.get(day, 0.0) - amount_usd   # outflow

            # Overwrite this day's end-of-day snapshot (last trade of the day wins).
            snapshot_by_day[day] = book.snapshot()

        # Daily valuation pass across the wallet's full active range, carrying the
        # most recent end-of-day holdings forward over no-trade days. The range
        # extends to `end_day` so still-open positions keep accruing MTM, but we
        # stop early once the wallet has fully exited to cash after its last trade.
        trade_days = sorted(snapshot_by_day)
        last_trade_day = trade_days[-1]
        range_end = max(last_trade_day, end_day)
        full_range = pd.date_range(trade_days[0], range_end, freq="D")
        current_holdings: dict[str, float] = {}
        prev_value = 0.0
        for day in full_range:
            if day in snapshot_by_day:
                current_holdings = snapshot_by_day[day]
            elif day > last_trade_day and not current_holdings:
                break  # flat and done trading — nothing left to mark
            v_end = _value_holdings(current_holdings, prices, day)
            flow = flow_by_day.get(day, 0.0)
            denom = prev_value + 0.5 * flow
            if denom < min_capital_base:
                # Too little risk capital to score: dust denominators otherwise
                # turn a tiny absolute move into a 1e10-scale "return".
                daily_return = 0.0
            else:
                raw_return = (v_end - prev_value - flow) / denom
                # Winsorize: keeps a single mispriced thin-token MTM print from
                # blowing up the sleeve, and guarantees return > -1 so a mirrored
                # position can never be marked to a negative value.
                daily_return = max(return_floor, min(return_cap, raw_return))
            out_rows.append(
                {
                    "wallet": wallet,
                    "day": day,
                    "daily_return": float(daily_return),
                    "realized_pnl_usd": float(realized_by_day.get(day, 0.0)),
                    "risky_value_end": float(v_end),
                    "n_trades": int(ntrades_by_day.get(day, 0)),
                }
            )
            prev_value = v_end

    panel = pd.DataFrame(out_rows, columns=PANEL_COLUMNS)
    logger.info(
        "reconstructed PnL for {} wallets / {} wallet-day rows",
        n_wallets,
        len(panel),
    )
    return panel
