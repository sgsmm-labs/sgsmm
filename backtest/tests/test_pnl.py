"""
FIFO PnL + mark-to-market invariant tests for SGSMM.

These lock in the accounting rules the classifier panel depends on:
- FIFO realized PnL = proceeds - oldest-lot cost.
- Disposing inventory never acquired in-window realizes ZERO (no phantom gain).
- Stablecoin legs are cash: they never create risky exposure.
- A buy-and-hold wallet marks to the market VWAP on no-trade days.
"""

from __future__ import annotations

from datetime import datetime, timedelta

import pandas as pd

from src.panel import PANEL_COLUMNS, build_panel_from_trades
from src.pnl import is_stable, reconstruct_pnl

WETH = "0xweth"
WMNT = "0xwmnt"
USDC = "0xusdc"

_T0 = datetime(2026, 1, 1)


def _trade(
    wallet: str,
    day_offset: int,
    sold_sym: str,
    sold_addr: str,
    amt_sold: float,
    bought_sym: str,
    bought_addr: str,
    amt_bought: float,
    amount_usd: float,
    hour: int = 12,
) -> dict:
    """One canonical swap row (matches dune_source.CANONICAL_COLUMNS)."""
    block_time = _T0 + timedelta(days=day_offset, hours=hour)
    day = pd.Timestamp(_T0 + timedelta(days=day_offset))
    return {
        "block_time": block_time,
        "day": day,
        "wallet": wallet,
        "tx_hash": f"0x{wallet[-3:]}{day_offset}{hour}",
        "token_bought": bought_sym,
        "token_bought_address": bought_addr,
        "amt_bought": amt_bought,
        "token_sold": sold_sym,
        "token_sold_address": sold_addr,
        "amt_sold": amt_sold,
        "amount_usd": amount_usd,
        "project": "test_dex",
    }


def _frame(rows: list[dict]) -> pd.DataFrame:
    return pd.DataFrame(rows)


def test_is_stable_classifies_known_symbols():
    assert is_stable("USDC")
    assert is_stable("usdt")
    assert is_stable("USDY")
    assert not is_stable("WETH")
    assert not is_stable(None)


def test_fifo_realized_pnl_simple_round_trip():
    """Buy 10 WETH for $1000, sell for $1500 -> realized PnL = $500."""
    rows = [
        _trade("0xhodl", 0, "USDC", USDC, 1000, "WETH", WETH, 10, 1000),
        _trade("0xhodl", 1, "WETH", WETH, 10, "USDC", USDC, 1500, 1500),
    ]
    out = reconstruct_pnl(_frame(rows))
    realized = out["realized_pnl_usd"].sum()
    assert abs(realized - 500.0) < 1e-6, f"expected $500 realized, got {realized}"


def test_fifo_pops_oldest_lot_first():
    """Two lots (10@$100, 10@$200); selling 10 matches the $100 lot -> $500."""
    rows = [
        _trade("0xfifo", 0, "USDC", USDC, 1000, "WETH", WETH, 10, 1000),  # 10 @ 100
        _trade("0xfifo", 1, "USDC", USDC, 2000, "WETH", WETH, 10, 2000),  # 10 @ 200
        _trade("0xfifo", 2, "WETH", WETH, 10, "USDC", USDC, 1500, 1500),  # sell 10 @ 150
    ]
    out = reconstruct_pnl(_frame(rows))
    day2 = pd.Timestamp(_T0 + timedelta(days=2))
    realized_day2 = out.loc[out["day"] == day2, "realized_pnl_usd"].sum()
    assert abs(realized_day2 - 500.0) < 1e-6, f"FIFO mismatch: {realized_day2}"


def test_uncovered_disposal_realizes_zero():
    """Selling a token never acquired in-window must NOT book phantom gain."""
    rows = [
        _trade("0xghost", 0, "WETH", WETH, 5, "USDC", USDC, 800, 800),
    ]
    out = reconstruct_pnl(_frame(rows))
    assert abs(out["realized_pnl_usd"].sum() - 0.0) < 1e-9


def test_stable_to_stable_has_no_risky_exposure():
    """A USDC->USDT swap creates no risky position and no realized PnL."""
    rows = [
        _trade("0xcash", 0, "USDC", USDC, 1000, "USDT", "0xusdt", 1000, 1000),
    ]
    out = reconstruct_pnl(_frame(rows))
    assert out["risky_value_end"].abs().sum() < 1e-9
    assert out["realized_pnl_usd"].abs().sum() < 1e-9


def test_buy_and_hold_marks_to_market_on_no_trade_day():
    """A holder marks to the market VWAP set by another wallet's later trade."""
    rows = [
        # Holder buys 10 WETH at $100 on day 0 and never trades again.
        _trade("0xhold", 0, "USDC", USDC, 1000, "WETH", WETH, 10, 1000),
        # A different wallet trades WETH at $150 on day 1, setting that day's VWAP.
        _trade("0xmkt", 1, "USDC", USDC, 150, "WETH", WETH, 1, 150),
    ]
    out = reconstruct_pnl(_frame(rows))
    day1 = pd.Timestamp(_T0 + timedelta(days=1))
    hold_day1 = out[(out["wallet"] == "0xhold") & (out["day"] == day1)]
    assert len(hold_day1) == 1, "holder did not accrue a no-trade MTM row"
    ret = float(hold_day1.iloc[0]["daily_return"])
    assert abs(ret - 0.5) < 1e-6, f"expected +50% MTM, got {ret}"
    # Risky value marked from $1000 to $1500.
    assert abs(float(hold_day1.iloc[0]["risky_value_end"]) - 1500.0) < 1e-6


def test_entry_day_return_is_flat_not_inflated_by_inflow():
    """Funding a new position (stable->risky) is a flow, not performance."""
    rows = [
        _trade("0xnew", 0, "USDC", USDC, 1000, "WETH", WETH, 10, 1000),
    ]
    out = reconstruct_pnl(_frame(rows))
    assert abs(out.iloc[0]["daily_return"] - 0.0) < 1e-9


def test_build_panel_shape_and_defaults():
    """Panel exposes the exact simulator columns with a 1.0 default label."""
    rows = [
        _trade("0xhodl", 0, "USDC", USDC, 1000, "WETH", WETH, 10, 1000),
        _trade("0xhodl", 1, "WETH", WETH, 10, "USDC", USDC, 1500, 1500),
    ]
    panel = build_panel_from_trades(_frame(rows))
    assert list(panel.columns) == PANEL_COLUMNS
    assert (panel["label_score"] == 1.0).all()
    assert panel["epoch"].notna().all()
    assert (panel["n_observed_positions_90d"] >= 0).all()


def test_build_panel_respects_external_label_scores():
    rows = [
        _trade("0xhodl", 0, "USDC", USDC, 1000, "WETH", WETH, 10, 1000),
        _trade("0xhodl", 1, "WETH", WETH, 10, "USDC", USDC, 1500, 1500),
    ]
    panel = build_panel_from_trades(_frame(rows), label_scores={"0xhodl": 0.42})
    assert (panel["label_score"] == 0.42).all()
