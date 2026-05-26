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


def fetch_mantle_protocol_actors(
    protocol_addresses: list[str],
    topic0_hash: str,
    mantle_rpc: str = "https://rpc.mantle.xyz",
    block_window_days: int = 30,
    blocks_per_day: int = 43_200,  # Mantle ~2s block time
    chunk_size: int = 10_000,
) -> set[str]:
    """
    Scan Mantle Mainnet directly for distinct wallets that interacted with the
    given DeFi protocol contracts in the recent block window.

    Reads `eth_getLogs` for `topic0_hash` (e.g. keccak("Supply(...)") on Lendle)
    and extracts the indexed `user`/`onBehalfOf` field from topics.
    """
    latest_resp = httpx.post(
        mantle_rpc,
        json={"jsonrpc": "2.0", "method": "eth_blockNumber", "params": [], "id": 1},
        timeout=30.0,
    )
    latest_resp.raise_for_status()
    latest_block = int(latest_resp.json()["result"], 16)
    from_block = max(latest_block - (block_window_days * blocks_per_day), 0)

    logger.info(
        f"Scanning Mantle {len(protocol_addresses)} contract(s) topic={topic0_hash[:10]} "
        f"blocks {from_block}-{latest_block}"
    )

    actors: set[str] = set()
    for addr in protocol_addresses:
        cursor = from_block
        while cursor <= latest_block:
            chunk_end = min(cursor + chunk_size - 1, latest_block)
            resp = httpx.post(
                mantle_rpc,
                json={
                    "jsonrpc": "2.0",
                    "method": "eth_getLogs",
                    "params": [
                        {
                            "address": addr,
                            "topics": [topic0_hash],
                            "fromBlock": hex(cursor),
                            "toBlock": hex(chunk_end),
                        }
                    ],
                    "id": 1,
                },
                timeout=60.0,
            )
            data = resp.json()
            if "error" in data:
                logger.warning(f"  Mantle eth_getLogs error {cursor}-{chunk_end}: {data['error']}")
                cursor = chunk_end + 1
                continue
            for log in data.get("result", []):
                # Conventional: topic[1] or topic[2] = indexed user
                for ti in (1, 2):
                    if ti < len(log["topics"]):
                        actor = "0x" + log["topics"][ti][-40:]
                        actors.add(actor.lower())
            cursor = chunk_end + 1
        logger.info(f"  Contract {addr[:10]}… cumulative actors: {len(actors)}")

    return actors


def count_universe(
    block_window_days: int = 30,
    activity_window_days: int = 30,
    include_bridge: bool = False,
) -> UniverseCounts:
    """
    Phase 0 universe count.

    By default, scans Mantle DeFi protocols directly (Lendle / Init / Agni / Moe
    Supply / Borrow / Swap events) — this gives the *active DeFi universe* on
    Mantle, which is the right denominator for SGSMM eligibility.

    Optionally includes L1 bridge arrivals as an additional source (narrower —
    misses USDC/USDT bridges and 3rd-party L0/Stargate paths).
    """
    try:
        from .data_loader import ADDRESSES, topic0
    except ImportError:
        from data_loader import ADDRESSES, topic0

    # Lendle = Aave V2 fork → uses Deposit/Withdraw/Borrow/Repay V2 signatures
    lendle_actors: set[str] = set()
    for event_name in (
        "Deposit_V2",
        "Withdraw_V2",
        "Borrow_V2",
        "Repay_V2",
        "LiquidationCall_V2",
    ):
        actors = fetch_mantle_protocol_actors(
            protocol_addresses=[ADDRESSES.lendle_lending_pool],
            topic0_hash=topic0(event_name),
            block_window_days=block_window_days,
        )
        lendle_actors |= actors

    bridge_actors: set[str] = set()
    if include_bridge:
        bridge_arrivals = fetch_bridge_arrivals(block_window_days=block_window_days)
        bridge_actors = {w.lower() for w in bridge_arrivals}

    active = lendle_actors | bridge_actors
    return UniverseCounts(
        total_bridge_arrivals=len(bridge_actors),
        distinct_arriving_wallets=len(active),
        active_last_30d_on_mantle=len(active),
        passes_gate=len(active) >= 500,
    )


if __name__ == "__main__":
    counts = count_universe()
    print(f"Bridge arrivals (180d): {counts.total_bridge_arrivals}")
    print(f"Active on Mantle (30d): {counts.active_last_30d_on_mantle}")
    print(f"Passes 500-wallet gate: {counts.passes_gate}")
