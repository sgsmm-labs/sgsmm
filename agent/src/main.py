"""
SGSMM agent entry point — FastAPI app + scheduler loop.

Endpoints:
    GET /health           — liveness probe
    GET /status           — current vault state + last decision
    GET /decisions/recent — last N decisions emitted to DecisionLog
    POST /rebalance       — force-trigger a rebalance cycle (admin only)
"""

from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI
from loguru import logger

from .config import AgentSettings


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = AgentSettings()
    logger.info(f"SGSMM agent starting (chain {settings.mantle_chain_id})")
    app.state.settings = settings
    yield
    logger.info("SGSMM agent shutting down")


app = FastAPI(
    title="SGSMM Agent",
    description="Manager Scoring Infrastructure for Mantle — autonomous Sortino-gated mirror agent",
    version="0.1.0",
    lifespan=lifespan,
)


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/status")
def status() -> dict:
    """Current vault snapshot — to be filled with on-chain reads in Phase 6."""
    return {
        "vault_nav": None,
        "active_mirrors": [],
        "last_rebalance": None,
        "next_rebalance": None,
        "frozen": False,
    }


def run() -> None:
    """Console script entry point."""
    import uvicorn

    uvicorn.run("src.main:app", host="0.0.0.0", port=8080, reload=False)


if __name__ == "__main__":
    run()
