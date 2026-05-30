# SGSMM Agent

Autonomous runtime for **SGSMM (Sortino-Gated Smart Money Mirror)** — a Mantle
agent that mirrors only wallets clearing a downside-risk-adjusted (Sortino) gate
and auto-defunds them on drawdown.

This package contains:

- `src/main.py` — FastAPI service (health/status/rebalance) for the on-chain agent.
- `src/bot.py` — **Telegram smart-money tracker bot** (AI Alpha & Data track demo).
- `src/bot_data.py` — pure, Telegram-free data layer over the committed snapshot.
- `scripts/build_snapshot.py` — distils the proven backtest panel into the bot's snapshot.

## Telegram bot

A read-only Telegram interface over the proven SGSMM analytics core. It serves a
committed snapshot built from **real Mantle DEX data** (`backtest/results/panel_real.csv`,
reconstructed trades) and scored with the exact Sortino-gated classifier the agent
trades on. Judges can DM the bot and inspect the smart-money leaderboard, per-wallet
verdicts, aggregate signals, and the on-chain anomaly feed.

### Commands

| Command | What it does |
| --- | --- |
| `/start` | Intro + quick pitch |
| `/help` | Command list + verdict legend |
| `/leaderboard` | Top smart-money wallets ranked by rolling 90d Sortino |
| `/wallet <address>` | Verdict + stats for one wallet (case-insensitive) |
| `/signals` | Aggregate ENTER / DEFUND / EMERGENCY / anomaly counts |
| `/anomaly` | Wallets breaching the drawdown circuit-breaker |

Verdicts: 🟢 `ENTER` · ⚪ `SKIP` · 🟠 `DEFUND` · 🔴 `EMERGENCY_UNWIND`, derived
from the SGSMM thresholds (Sortino entry ≥ 1.5, defund < 0.5, label ≥ 0.7,
≥ 20 observed 90d positions, 30d drawdown ≥ 15% ⇒ emergency).

### Get a bot token from BotFather (≈ 2 min)

1. In Telegram, open a chat with [`@BotFather`](https://t.me/BotFather).
2. Send `/newbot`.
3. Give it a **display name** (e.g. `SGSMM Smart Money`) and a **username** ending
   in `bot` (e.g. `sgsmm_smartmoney_bot`).
4. BotFather replies with a token like `123456789:AAH...`. Copy it.

### Configure and run

```powershell
# 1. Put the token in agent/.env (see agent/.env.example)
#    TELEGRAM_BOT_TOKEN=123456789:AAH...

# 2. (First time only) build the snapshot from the real Mantle panel
agent\.venv\Scripts\python.exe agent/scripts/build_snapshot.py

# 3. Run the bot (long-polls Telegram; Ctrl+C to stop)
agent\.venv\Scripts\python.exe -m src.bot
```

Run `python -m src.bot` **from inside the `agent/` directory** so the `.env` file
and the `src` package resolve. If `TELEGRAM_BOT_TOKEN` is missing, the bot logs a
clear error and exits — it never connects to Telegram without a token.

Then open your bot in Telegram (the `t.me/<username>` link from BotFather) and
send `/start`.

### Rebuilding the snapshot

The bot reads `agent/data/smartmoney_snapshot.json` (committed). Regenerate it
whenever the underlying panel changes:

```powershell
agent\.venv\Scripts\python.exe agent/scripts/build_snapshot.py
```

### Tests

The data layer is unit-tested offline (no token, no network):

```powershell
agent\.venv\Scripts\python.exe -m pytest agent/tests/test_bot_data.py -v
```
