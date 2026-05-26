"""
Mantle smart-money universe counter.

Cross-references Ethereum mainnet wallets that bridged to Mantle via
L1StandardBridge.ETHBridgeInitiated, then checks recent Mantle activity to
determine the SGSMM-eligible universe size.

Used in Phase 0 gate verification — if active universe < 500 wallets,
strategy pivots.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta

import httpx
from loguru import logger

# L1StandardBridgeProxy (Ethereum Mainnet)
L1_BRIDGE_PROXY = "0x95fC37A27a2f68e3A647CDc081F0A89bb47c3012"

# event ETHBridgeInitiated(address indexed from, address indexed to, uint256 amount, bytes extraData)
# topic0 = keccak256("ETHBridgeInitiated(address,address,uint256,bytes)")
ETH_BRIDGE_INITIATED_TOPIC = (
    "0x2849b43074093a05396b6f2a937dee8565b15a48a7b3d4bffb732a5017380af5"
)

ETHEREUM_PUBLIC_RPC = "https://ethereum-rpc.publicnode.com"


@dataclass(frozen=True)
class UniverseCounts:
    """Smart-money universe sizing for Phase 0 gate."""

    total_bridge_arrivals: int
    distinct_arriving_wallets: int
    active_last_30d_on_mantle: int
    passes_gate: bool  # True if active_last_30d_on_mantle >= 500


def fetch_bridge_arrivals(
    rpc_url: str = ETHEREUM_PUBLIC_RPC,
    block_window_days: int = 180,
    blocks_per_day: int = 7200,
) -> list[str]:
    """
    Pull all addresses that called the L1 → Mantle bridge in the last N days.

    Returns the list of unique "to" addresses (the Mantle-side recipient).
    """
    # Latest Ethereum block
    latest_resp = httpx.post(
        rpc_url,
        json={"jsonrpc": "2.0", "method": "eth_blockNumber", "params": [], "id": 1},
        timeout=30.0,
    )
    latest_resp.raise_for_status()
    latest_block = int(latest_resp.json()["result"], 16)
    from_block = latest_block - (block_window_days * blocks_per_day)

    logger.info(
        f"Scanning Ethereum L1 bridge events from block {from_block} to {latest_block}"
    )

    wallets: set[str] = set()

    # Paginate to respect RPC limits
    chunk = 10_000
    cursor = from_block
    while cursor <= latest_block:
        chunk_end = min(cursor + chunk - 1, latest_block)
        params = [
            {
                "address": L1_BRIDGE_PROXY,
                "topics": [ETH_BRIDGE_INITIATED_TOPIC],
                "fromBlock": hex(cursor),
                "toBlock": hex(chunk_end),
            }
        ]
        resp = httpx.post(
            rpc_url,
            json={"jsonrpc": "2.0", "method": "eth_getLogs", "params": params, "id": 1},
            timeout=60.0,
        )
        resp.raise_for_status()
        data = resp.json()
        if "error" in data:
            logger.warning(f"Chunk [{cursor}-{chunk_end}] error: {data['error']}")
            cursor = chunk_end + 1
            continue
        for log in data["result"]:
            # topic[1] = indexed `from`, topic[2] = indexed `to`
            if len(log["topics"]) >= 3:
                to_addr = "0x" + log["topics"][2][-40:]
                wallets.add(to_addr.lower())
        logger.debug(f"[{cursor}-{chunk_end}] cumulative wallets: {len(wallets)}")
        cursor = chunk_end + 1

    return sorted(wallets)


def filter_active_on_mantle(
    candidate_wallets: list[str],
    mantle_rpc: str = "https://rpc.mantle.xyz",
    activity_window_days: int = 30,
    blocks_per_day: int = 86_400,  # Mantle ~2s block time
) -> list[str]:
    """
    Filter candidate wallets to those with on-chain activity on Mantle in the last N days.

    Uses eth_getTransactionCount as a fast proxy. For backtest needs, a more nuanced
    "recent activity" probe (e.g. eth_getLogs for the wallet) is preferred.
    """
    # Snapshot at "latest" and at "latest - N days" — compare nonces
    latest_resp = httpx.post(
        mantle_rpc,
        json={"jsonrpc": "2.0", "method": "eth_blockNumber", "params": [], "id": 1},
        timeout=30.0,
    )
    latest_resp.raise_for_status()
    latest_block = int(latest_resp.json()["result"], 16)
    window_start_block = max(latest_block - (activity_window_days * blocks_per_day), 0)

    active: list[str] = []
    for i, wallet in enumerate(candidate_wallets):
        latest_nonce_resp = httpx.post(
            mantle_rpc,
            json={
                "jsonrpc": "2.0",
                "method": "eth_getTransactionCount",
                "params": [wallet, "latest"],
                "id": 1,
            },
            timeout=15.0,
        )
        snapshot_nonce_resp = httpx.post(
            mantle_rpc,
            json={
                "jsonrpc": "2.0",
                "method": "eth_getTransactionCount",
                "params": [wallet, hex(window_start_block)],
                "id": 1,
            },
            timeout=15.0,
        )
        try:
            latest_nonce = int(latest_nonce_resp.json()["result"], 16)
            snapshot_nonce = int(snapshot_nonce_resp.json()["result"], 16)
        except (KeyError, TypeError):
            continue
        if latest_nonce > snapshot_nonce:
            active.append(wallet)
        if (i + 1) % 50 == 0:
            logger.info(f"Probed {i + 1}/{len(candidate_wallets)} wallets; {len(active)} active")

    return active


def count_universe(
    block_window_days: int = 180,
    activity_window_days: int = 30,
) -> UniverseCounts:
    """End-to-end universe count for Phase 0 gate decision."""
    bridge_arrivals = fetch_bridge_arrivals(block_window_days=block_window_days)
    active = filter_active_on_mantle(
        candidate_wallets=bridge_arrivals,
        activity_window_days=activity_window_days,
    )

    return UniverseCounts(
        total_bridge_arrivals=len(bridge_arrivals),
        distinct_arriving_wallets=len(bridge_arrivals),
        active_last_30d_on_mantle=len(active),
        passes_gate=len(active) >= 500,
    )


if __name__ == "__main__":
    counts = count_universe()
    print(f"Bridge arrivals (180d): {counts.total_bridge_arrivals}")
    print(f"Active on Mantle (30d): {counts.active_last_30d_on_mantle}")
    print(f"Passes 500-wallet gate: {counts.passes_gate}")
