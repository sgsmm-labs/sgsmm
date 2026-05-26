"""
SGSMM agent runtime configuration.

All values load from environment variables (12-factor compliant); secrets
never enter code. See .env.example for the full surface.
"""

from __future__ import annotations

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class AgentSettings(BaseSettings):
    """Runtime configuration for the SGSMM autonomous agent."""

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    # Mantle network
    mantle_rpc_url: str = Field(default="https://rpc.sepolia.mantle.xyz")
    mantle_chain_id: int = Field(default=5003)

    # Deployer / agent EOA (use eth-account keystore or fragment with care)
    agent_private_key: str | None = Field(default=None)

    # Deployed contract addresses (filled after Phase 4 deploy)
    sgsmm_vault: str | None = Field(default=None)
    mirror_executor: str | None = Field(default=None)
    decision_log: str | None = Field(default=None)
    agent_identity_nft: str | None = Field(default=None)

    # Indexer API (Ponder)
    indexer_api_url: str = Field(default="http://localhost:42069")

    # Label source (Phase 6)
    nansen_api_key: str | None = Field(default=None)
    label_source: str = Field(default="nansen")  # nansen | arkham | dune | bootstrap

    # Pyth Hermes (historical price oracle)
    pyth_hermes_url: str = Field(default="https://hermes.pyth.network")
    pyth_contract: str = Field(default="0x98046Bd286715D3B0BC227Dd7a956b83D8978603")

    # Operational
    rebalance_cadence_hours: int = Field(default=24)
    max_rebalances_per_24h: int = Field(default=3)
    log_level: str = Field(default="INFO")
