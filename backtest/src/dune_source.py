"""
Mantle on-chain DEX-trade source for SGSMM (Path B, Mirana Alpha & Data).

This is the project's CORE on-chain data source: every DEX swap on Mantle
(Merchant Moe, Agni, et al.) as recorded in Dune's decoded `dex.trades`
spellbook table. The submission requirement is "use Mantle on-chain data as a
core data source" — this module is that core.

Two acquisition paths (pick whichever your credentials allow):

  1. CSV export (zero-dependency, zero-credit):
        Run MANTLE_DEX_TRADES_SQL in the Dune web UI, export CSV, then:
            load_trades(csv_path="data/mantle_dex_trades.csv")

  2. Dune API (needs DUNE_API_KEY in env; uses httpx, already a dep):
            load_trades(query_id=123456)   # a saved query running the SQL below

Both return the SAME canonical schema so the rest of the pipeline is
acquisition-agnostic. No API key is ever read from arguments or logged.
"""

from __future__ import annotations

import os
from pathlib import Path

import pandas as pd
from loguru import logger

# ---------------------------------------------------------------------------
# The canonical Dune query. `dex.trades` is a cross-chain spellbook table with a
# `blockchain` partition column; filtering on 'mantle' gives every decoded swap
# on Merchant Moe + Agni (Mantle's two largest DEXs, ~53% of chain TVL) plus any
# other covered venue. `amount_usd` is Dune-computed, so we need no price oracle.
# ---------------------------------------------------------------------------
MANTLE_DEX_TRADES_SQL = """
SELECT
    block_time,
    block_date,
    tx_hash,
    tx_from,
    taker,
    token_bought_symbol,
    token_bought_address,
    token_bought_amount,
    token_sold_symbol,
    token_sold_address,
    token_sold_amount,
    amount_usd,
    project,
    version
FROM dex.trades
WHERE blockchain = 'mantle'
  AND block_time >= now() - interval '180' day
  AND amount_usd IS NOT NULL
  AND amount_usd > 0
ORDER BY block_time
""".strip()

# Canonical internal column set every downstream module relies on.
CANONICAL_COLUMNS = [
    "block_time",
    "day",
    "wallet",
    "tx_hash",
    "token_bought",
    "token_bought_address",
    "amt_bought",
    "token_sold",
    "token_sold_address",
    "amt_sold",
    "amount_usd",
    "project",
]


def _normalize(df: pd.DataFrame, wallet_col: str = "tx_from") -> pd.DataFrame:
    """
    Map raw `dex.trades` columns to the canonical schema.

    Args:
        df: raw frame with dex.trades column names (CSV export or API result).
        wallet_col: which address column identifies the trader. Default `tx_from`
            (the signing EOA — the right identity for smart-money copy-tracking).
            Use `taker` if you want the immediate on-chain taker instead.

    Returns:
        DataFrame with CANONICAL_COLUMNS, sorted by block_time, USD-priced rows only.
    """
    df = df.copy()
    df.columns = [c.strip().lower() for c in df.columns]

    if wallet_col not in df.columns:
        raise KeyError(
            f"wallet column {wallet_col!r} not in trades; got {list(df.columns)}"
        )

    block_time = pd.to_datetime(df["block_time"], utc=True, errors="coerce")
    out = pd.DataFrame(
        {
            "block_time": block_time,
            "day": block_time.dt.floor("D"),
            "wallet": df[wallet_col].astype(str).str.lower(),
            "tx_hash": df.get("tx_hash", pd.Series(index=df.index, dtype=str)),
            "token_bought": df.get("token_bought_symbol", "").astype(str),
            "token_bought_address": df.get("token_bought_address", "").astype(str).str.lower(),
            "amt_bought": pd.to_numeric(df.get("token_bought_amount"), errors="coerce"),
            "token_sold": df.get("token_sold_symbol", "").astype(str),
            "token_sold_address": df.get("token_sold_address", "").astype(str).str.lower(),
            "amt_sold": pd.to_numeric(df.get("token_sold_amount"), errors="coerce"),
            "amount_usd": pd.to_numeric(df["amount_usd"], errors="coerce"),
            "project": df.get("project", "").astype(str),
        }
    )

    out = out.dropna(subset=["block_time", "amount_usd"])
    out = out[out["amount_usd"] > 0]
    out = out.sort_values("block_time").reset_index(drop=True)
    logger.info(
        "normalized {} Mantle DEX trades across {} wallets / {} days",
        len(out),
        out["wallet"].nunique(),
        out["day"].nunique(),
    )
    return out[CANONICAL_COLUMNS]


def load_trades(
    csv_path: str | Path | None = None,
    query_id: int | None = None,
    wallet_col: str = "tx_from",
) -> pd.DataFrame:
    """
    Load Mantle DEX trades into the canonical schema.

    Exactly one of `csv_path` or `query_id` should be given. CSV is the
    zero-credit path (export from the Dune UI); query_id pulls live via the
    Dune API (requires DUNE_API_KEY in the environment).
    """
    if csv_path is not None:
        path = Path(csv_path)
        if not path.exists():
            raise FileNotFoundError(
                f"trades CSV not found: {path}. Run MANTLE_DEX_TRADES_SQL in the "
                "Dune UI and export to this path."
            )
        raw = pd.read_csv(path)
        return _normalize(raw, wallet_col=wallet_col)

    if query_id is not None:
        return _normalize(_fetch_dune_api(query_id), wallet_col=wallet_col)

    raise ValueError("provide either csv_path (Dune UI export) or query_id (Dune API)")


def _fetch_dune_api(query_id: int) -> pd.DataFrame:
    """
    Pull a saved query's latest result via the Dune API using httpx.

    The API key is read ONLY from the DUNE_API_KEY environment variable and is
    never accepted as an argument, logged, or persisted.
    """
    import httpx

    api_key = os.environ.get("DUNE_API_KEY")
    if not api_key:
        raise RuntimeError(
            "DUNE_API_KEY not set. Either export it, or use the CSV path "
            "(load_trades(csv_path=...)) which needs no key."
        )

    url = f"https://api.dune.com/api/v1/query/{query_id}/results"
    logger.info("fetching Dune query {} results via API", query_id)
    resp = httpx.get(url, headers={"X-Dune-API-Key": api_key}, timeout=120.0)
    resp.raise_for_status()
    rows = resp.json().get("result", {}).get("rows", [])
    if not rows:
        raise RuntimeError(f"Dune query {query_id} returned no rows")
    return pd.DataFrame(rows)
