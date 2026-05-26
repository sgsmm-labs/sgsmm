"""
Mantle on-chain data loaders for SGSMM Phase 1 backtest.

Pulls historical events from confirmed Mantle protocols (Lendle, Init Capital,
Agni Finance, Merchant Moe). Pendle SKIPPED — all Mantle markets dormant.

References: SGSMM/docs-private/data-sources.md, reference_mantle_addresses memory.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import httpx
from loguru import logger

MANTLE_MAINNET_RPC = "https://rpc.mantle.xyz"
MANTLE_SEPOLIA_RPC = "https://rpc.sepolia.mantle.xyz"

MANTLE_MAINNET_CHAIN_ID = 5000
MANTLE_SEPOLIA_CHAIN_ID = 5003


@dataclass(frozen=True)
class ProtocolAddresses:
    """Canonical contract addresses per protocol (Mantle Mainnet)."""

    lendle_lending_pool: str = "0xCFa5aE7c2CE8Fadc6426C1ff872cA45378Fb7cF3"
    lendle_data_provider: str = "0x552b9e4bae485C4B7F540777d7D25614CdB84773"
    lendle_oracle: str = "0x870c9692Ab04944C86ec6FEeF63F261226506EfC"

    init_core: str = "0x972BcB0284cca0152527c4f70f8F689852bCAFc5"
    init_pos_manager: str = "0x0e7401707CD08c03CDb53DAEF3295DDFb68BBa92"
    init_risk_manager: str = "0x0c03cd3e8b669680Bf306Fc72F1dc2cAC592f951"

    agni_factory: str = "0x25780dc8Fc3cfBD75F33bFdAb65e969b603b2035"
    agni_swap_router: str = "0x319B69888b0d11cEC22caA5034e25FfFBDc88421"
    agni_position_manager: str = "0x218Bf598D1453383e2F4AA7b14FFB9BFb102D637"

    moe_lb_factory: str = "0xa6630671775c4EA2743840F9A5016dCf2A104054"
    moe_lb_router: str = "0x013e138EF6008ae5FDFDE29700e3f2Bc61d21E3a"

    pyth_mainnet: str = "0xA2aa501b19aff244D90cc15a4Cf739D2725B5729"
    pyth_sepolia: str = "0x98046Bd286715D3B0BC227Dd7a956b83D8978603"

    meth_token: str = "0xE6829d9a7eE3040e1276Fa75293Bde931859e8fA"
    usdy_token: str = "0x5bE26527e817998A7206475496fDE1E68957c5A6"


ADDRESSES = ProtocolAddresses()


def rpc_call(rpc_url: str, method: str, params: list, request_id: int = 1) -> dict:
    """Single JSON-RPC call to a Mantle node."""
    payload = {"jsonrpc": "2.0", "method": method, "params": params, "id": request_id}
    response = httpx.post(rpc_url, json=payload, timeout=30.0)
    response.raise_for_status()
    return response.json()


def get_block_number(rpc_url: str = MANTLE_MAINNET_RPC) -> int:
    """Latest block number on the target Mantle chain."""
    result = rpc_call(rpc_url, "eth_blockNumber", [])
    return int(result["result"], 16)


def get_logs(
    rpc_url: str,
    contract_address: str,
    topic0: str,
    from_block: int,
    to_block: int | str = "latest",
    chunk_size: int = 5_000,
) -> list[dict]:
    """
    Paginated eth_getLogs over a block range.

    Args:
        rpc_url: target chain RPC
        contract_address: contract emitting the event
        topic0: keccak256 hash of the event signature (e.g. "Supply(address,address,...)")
        from_block, to_block: inclusive block range
        chunk_size: max blocks per RPC call (Mantle public RPCs typically allow ~10k)

    Returns:
        List of raw log dicts.
    """
    all_logs: list[dict] = []
    latest = get_block_number(rpc_url) if to_block == "latest" else int(to_block)

    cursor = from_block
    while cursor <= latest:
        chunk_end = min(cursor + chunk_size - 1, latest)
        params = [
            {
                "address": contract_address,
                "topics": [topic0],
                "fromBlock": hex(cursor),
                "toBlock": hex(chunk_end),
            }
        ]
        result = rpc_call(rpc_url, "eth_getLogs", params)
        if "error" in result:
            logger.error(f"eth_getLogs failed [{cursor}-{chunk_end}]: {result['error']}")
            raise RuntimeError(result["error"])
        all_logs.extend(result["result"])
        logger.debug(f"Fetched {len(result['result'])} logs in [{cursor}-{chunk_end}]")
        cursor = chunk_end + 1

    return all_logs


def cache_logs_to_parquet(logs: list[dict], path: Path) -> None:
    """Persist raw logs as JSON-line cache; parquet conversion handled per-protocol."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        for log in logs:
            f.write(json.dumps(log) + "\n")
    logger.info(f"Cached {len(logs)} logs → {path}")


# Event signature strings — resolve topic0 via keccak256 at runtime
# (avoid hardcoding hashes that may be wrong; see notebooks/01_data_pull.ipynb).
EVENT_SIGNATURES: dict[str, str] = {
    # Lendle (Aave V2 fork on Mantle — uses Deposit/Withdraw, not V3 Supply)
    # V2 events
    "Deposit_V2": "Deposit(address,address,address,uint256,uint16)",
    "Withdraw_V2": "Withdraw(address,address,address,uint256)",
    "Borrow_V2": "Borrow(address,address,address,uint256,uint256,uint256,uint16)",
    "Repay_V2": "Repay(address,address,address,uint256)",
    "LiquidationCall_V2": "LiquidationCall(address,address,address,uint256,uint256,address,bool)",
    # V3 events (kept for Aave V3 forks like Init Capital if they emit V3 style)
    "Supply": "Supply(address,address,address,uint256,uint16)",
    "Borrow": "Borrow(address,address,address,uint256,uint8,uint256,uint16)",
    "Repay": "Repay(address,address,address,uint256,bool)",
    "LiquidationCall": "LiquidationCall(address,address,address,uint256,uint256,address,bool)",
    # Agni Finance (Uniswap V3 fork) — Factory + Pool
    "PoolCreated": "PoolCreated(address,address,uint24,int24,address)",
    "Swap_V3": "Swap(address,address,int256,int256,uint160,uint128,int24)",
    "Mint_V3": "Mint(address,address,int24,int24,uint128,uint256,uint256)",
    "Burn_V3": "Burn(address,int24,int24,uint128,uint256,uint256)",
    # Merchant Moe (Liquidity Book v2.2)
    "LBPairCreated": "LBPairCreated(address,address,uint256,uint256)",
    "LBPair_Swap": "Swap(address,address,uint24,bytes32,bytes32,uint24,bytes32,bytes32)",
    # L1StandardBridge (Ethereum mainnet → Mantle)
    "ETHBridgeInitiated": "ETHBridgeInitiated(address,address,uint256,bytes)",
}


def topic0(event_name: str) -> str:
    """Resolve topic0 (32-byte keccak hash) for a known event signature."""
    from eth_utils import keccak

    if event_name not in EVENT_SIGNATURES:
        raise KeyError(f"Unknown event {event_name!r}; known: {sorted(EVENT_SIGNATURES)}")
    return "0x" + keccak(text=EVENT_SIGNATURES[event_name]).hex()
