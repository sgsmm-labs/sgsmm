"""
SGSMM smart-money Telegram bot (AI Alpha & Data track demo).

A read-only Telegram interface over the proven SGSMM analytics core. It serves
the committed snapshot (real Mantle DEX data, distilled by
``agent/scripts/build_snapshot.py``) through the pure ``bot_data`` layer — judges
can DM the bot and inspect the smart-money leaderboard, per-wallet verdicts,
aggregate signals, and the on-chain anomaly feed.

Run (after exporting a token from @BotFather into agent/.env)::

    agent\\.venv\\Scripts\\python.exe -m src.bot

The token is read from ``AgentSettings().telegram_bot_token``. If it is missing
the bot logs a clear error and exits — it never invents a token and never
connects to Telegram during import or tests.
"""

from __future__ import annotations

import json
import re
import sys

from loguru import logger
from telegram import LinkPreviewOptions, Update
from telegram.constants import ParseMode
from telegram.ext import Application, CommandHandler, ContextTypes, Defaults

from . import bot_data
from .config import AgentSettings

_EVM_ADDRESS_RE = re.compile(r"0x[0-9a-fA-F]{40}")

PITCH = (
    "*SGSMM* — Sortino-Gated Smart Money Mirror: an autonomous Mantle agent that "
    "mirrors only wallets clearing a downside-risk-adjusted (Sortino) gate, and "
    "auto-defunds them on drawdown."
)

_VERDICT_EMOJI = {
    "ENTER": "🟢",
    "SKIP": "⚪",
    "DEFUND": "🟠",
    "EMERGENCY_UNWIND": "🔴",
}


def _short_addr(address: str) -> str:
    """Compact an EVM address for inline display: 0x1234…abcd."""
    if len(address) <= 12:
        return address
    return f"{address[:6]}…{address[-4:]}"


_EXPLORER = "https://mantlescan.xyz/address/"


def _addr_link(address: str, *, full: bool = False) -> str:
    """Render a wallet as a Markdown link to its Mantle explorer page.

    Only ever called on snapshot-derived (trusted, clean-hex) addresses — never
    on raw user input — so the label needs no Markdown escaping.
    """
    label = address if full else _short_addr(address)
    return f"[{label}]({_EXPLORER}{address})"


def _fmt_pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:+.1f}%"


_SORTINO_CAP = 10.0


def _fmt_sortino(value: float | None) -> str:
    """Sortino with an explicit cap marker (the backtest caps |Sortino| at 10)."""
    if value is None:
        return "n/a"
    try:
        x = float(value)
    except (TypeError, ValueError):
        return str(value)
    if x >= _SORTINO_CAP:
        return "10.00⁺"
    if x <= -_SORTINO_CAP:
        return "-10.00"
    return f"{x:.2f}"


def _fmt_dd(value: float | None) -> str:
    """30-day realized drawdown as a signed-loss percentage (e.g. -33%)."""
    if value is None:
        return "n/a"
    return f"-{value * 100:.0f}%"


def _md_escape(text: str) -> str:
    """Escape the few legacy-Markdown metacharacters we echo back (addresses)."""
    for ch in ("_", "*", "`", "["):
        text = text.replace(ch, f"\\{ch}")
    return text


# --- command handlers ---------------------------------------------------------


async def cmd_start(update: Update, _ctx: ContextTypes.DEFAULT_TYPE) -> None:
    msg = (
        "👋 *Welcome to the SGSMM Smart-Money Tracker*\n\n"
        f"{PITCH}\n\n"
        "I track real Mantle DEX wallets and score them with the same "
        "Sortino-gated classifier the agent trades on.\n\n"
        "Try */leaderboard*, */signals*, or */anomaly*. Send */help* for everything."
    )
    await update.message.reply_text(msg, parse_mode=ParseMode.MARKDOWN)


async def cmd_help(update: Update, _ctx: ContextTypes.DEFAULT_TYPE) -> None:
    msg = (
        "*SGSMM bot — commands*\n\n"
        "/start — intro\n"
        "/help — this message\n"
        "/leaderboard — top smart-money wallets by 90d Sortino\n"
        "/wallet `<address>` — verdict + stats for one wallet\n"
        "/signals — aggregate ENTER/DEFUND/anomaly counts\n"
        "/anomaly — wallets breaching the drawdown circuit-breaker\n\n"
        f"{PITCH}\n\n"
        "_Verdicts:_ 🟢 ENTER  ⚪ SKIP  🟠 DEFUND  🔴 EMERGENCY\\_UNWIND"
    )
    await update.message.reply_text(msg, parse_mode=ParseMode.MARKDOWN)


async def cmd_leaderboard(update: Update, _ctx: ContextTypes.DEFAULT_TYPE) -> None:
    try:
        rows = bot_data.leaderboard(top_n=10)
    except FileNotFoundError:
        await update.message.reply_text(_SNAPSHOT_MISSING)
        return
    except (json.JSONDecodeError, KeyError):
        await update.message.reply_text(_SNAPSHOT_MALFORMED)
        return

    if not rows:
        await update.message.reply_text("No wallets in the current snapshot.")
        return

    lines = [
        "*🏆 SGSMM Smart-Money Leaderboard*",
        "_ranked by 90d Sortino · capped at 10_",
        "",
        "🟢 ENTER · 🔴 EMERGENCY · 🟠 DEFUND · ⚪ SKIP",
        "_color = verdict · 30d drawdown ≥15% ⇒ 🔴 unwind_",
        "",
    ]
    for r in rows:
        emoji = _VERDICT_EMOJI.get(r["verdict"], "")
        lines.append(
            f"{r['rank']}. {_addr_link(r['wallet_address'])} {emoji} "
            f"Sortino *{_fmt_sortino(r['rolling_90d_sortino'])}* · "
            f"dd *{_fmt_dd(r['realized_dd_30d'])}* · "
            f"ret {_fmt_pct(r['cumulative_return'])} · "
            f"{r['n_observed_positions_90d']} trades"
        )
    lines.append("")
    lines.append("Tip: `/wallet <address>` for a full breakdown.")
    await update.message.reply_text("\n".join(lines), parse_mode=ParseMode.MARKDOWN)


async def cmd_wallet(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not ctx.args:
        await update.message.reply_text(
            "Usage: `/wallet <0x-address>`", parse_mode=ParseMode.MARKDOWN
        )
        return

    address = ctx.args[0].strip()

    # Fix #7: validate address BEFORE touching Markdown — never echo raw user
    # input through legacy Markdown (unbalanced backticks -> Telegram 400).
    if not _EVM_ADDRESS_RE.fullmatch(address):
        await update.message.reply_text(
            "Invalid address. Expected a 42-character hex address starting with 0x.",
            parse_mode=None,
        )
        return

    try:
        record = bot_data.wallet_lookup(address)
    except FileNotFoundError:
        await update.message.reply_text(_SNAPSHOT_MISSING)
        return
    except (json.JSONDecodeError, KeyError):
        await update.message.reply_text(_SNAPSHOT_MALFORMED)
        return

    if record is None:
        await update.message.reply_text(
            f"No record for `{_md_escape(_short_addr(address))}` in the current "
            "snapshot.\nTry `/leaderboard` to see tracked wallets.",
            parse_mode=ParseMode.MARKDOWN,
        )
        return

    emoji = _VERDICT_EMOJI.get(record.get("verdict", ""), "")
    lines = [
        f"*Wallet* {_addr_link(record['wallet_address'], full=True)}",
        "",
        f"{emoji} *Verdict:* {_md_escape(str(record.get('verdict', 'n/a')))}",
        # Fix #2: cap-consistent Sortino display
        f"*90d Sortino:* {_fmt_sortino(record.get('rolling_90d_sortino'))}",
        # Fix #1: drawdown is a loss — use _fmt_dd (not _fmt_pct which adds "+")
        f"*30d drawdown:* {_fmt_dd(record.get('realized_dd_30d'))}",
    ]
    if record.get("rank"):
        lines.insert(2, f"*Leaderboard rank:* #{record['rank']}")
    if "n_observed_positions_90d" in record:
        lines.append(f"*Observed 90d trades:* {record['n_observed_positions_90d']}")
    if record.get("cumulative_return") is not None:
        lines.append(f"*Cumulative return:* {_fmt_pct(record['cumulative_return'])}")
    if record.get("win_rate") is not None:
        lines.append(f"*Win rate:* {record['win_rate'] * 100:.0f}%")
    if record.get("reason"):
        lines.append(f"\n⚠️ _{_md_escape(str(record['reason']))}_")
    await update.message.reply_text("\n".join(lines), parse_mode=ParseMode.MARKDOWN)


async def cmd_signals(update: Update, _ctx: ContextTypes.DEFAULT_TYPE) -> None:
    try:
        s = bot_data.signals_summary()
    except FileNotFoundError:
        await update.message.reply_text(_SNAPSHOT_MISSING)
        return
    except (json.JSONDecodeError, KeyError):
        await update.message.reply_text(_SNAPSHOT_MALFORMED)
        return

    lines = [
        "*📊 SGSMM Signal Summary*",
        f"_epoch {s.get('latest_epoch', 'n/a')} · {s.get('total_wallets', 0)} wallets "
        f"· {s.get('epochs_observed', 0)} epochs_",
        "",
        f"🟢 ENTER: *{s['n_enter']}*",
        f"⚪ SKIP: *{s['n_skip']}*",
        f"🟠 DEFUND: *{s['n_defund']}*",
        f"🔴 EMERGENCY\\_UNWIND: *{s['n_emergency']}*",
        f"⚠️ anomalies flagged: *{s['n_anomalies']}*",
    ]
    if s.get("top_enter_candidates"):
        lines.append("")
        lines.append("*Strongest ENTER candidates:*")
        for c in s["top_enter_candidates"]:
            lines.append(
                f"• {_addr_link(c['wallet_address'])} "
                f"Sortino {c['rolling_90d_sortino']:.2f}"
            )
    lines.append("")
    lines.append(f"_{s.get('source', '')}_")
    await update.message.reply_text("\n".join(lines), parse_mode=ParseMode.MARKDOWN)


async def cmd_anomaly(update: Update, _ctx: ContextTypes.DEFAULT_TYPE) -> None:
    try:
        rows = bot_data.anomalies(top_n=10)
    except FileNotFoundError:
        await update.message.reply_text(_SNAPSHOT_MISSING)
        return
    except (json.JSONDecodeError, KeyError):
        await update.message.reply_text(_SNAPSHOT_MALFORMED)
        return

    if not rows:
        await update.message.reply_text("✅ No anomalies in the current snapshot.")
        return

    lines = [
        "*🚨 On-Chain Anomaly Feed*",
        "_wallets tripping the drawdown / Sortino-decay gates_",
        "",
    ]
    for a in rows:
        emoji = _VERDICT_EMOJI.get(a.get("verdict", ""), "🔴")
        lines.append(
            f"{emoji} {_addr_link(a['wallet_address'])} — "
            # Fix #1: use _fmt_dd so loss is shown as "-33%" not "+33%"
            f"DD *{_fmt_dd(a.get('realized_dd_30d'))}* · "
            # Fix #2: use _fmt_sortino for cap-consistent "10.00+" display
            f"Sortino {_fmt_sortino(a.get('rolling_90d_sortino'))}"
        )
    await update.message.reply_text("\n".join(lines), parse_mode=ParseMode.MARKDOWN)


_SNAPSHOT_MISSING = (
    "Snapshot not found. The operator must run "
    "`agent/scripts/build_snapshot.py` to generate it."
)

_SNAPSHOT_MALFORMED = (
    "Snapshot unavailable or malformed. The operator must regenerate it with "
    "`agent/scripts/build_snapshot.py`."
)


async def on_error(update: object, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Global error handler: log the exception and best-effort reply to the user.

    Fix #3: registered via application.add_error_handler so unhandled exceptions
    in any handler are captured rather than silently swallowed by PTB.
    """
    logger.exception("Unhandled exception in update handler", exc_info=context.error)
    if isinstance(update, Update) and update.effective_message:
        try:
            await update.effective_message.reply_text(
                "An unexpected error occurred. Please try again later.",
                parse_mode=None,
            )
        except Exception:  # noqa: BLE001 — best-effort, never raises
            pass


def build_application(token: str) -> Application:
    """Wire up the PTB application and command handlers (no network I/O)."""
    defaults = Defaults(
        parse_mode=ParseMode.MARKDOWN,
        link_preview_options=LinkPreviewOptions(is_disabled=True),
    )
    application = Application.builder().token(token).defaults(defaults).build()
    application.add_handler(CommandHandler("start", cmd_start))
    application.add_handler(CommandHandler("help", cmd_help))
    application.add_handler(CommandHandler("leaderboard", cmd_leaderboard))
    application.add_handler(CommandHandler("wallet", cmd_wallet))
    application.add_handler(CommandHandler("signals", cmd_signals))
    application.add_handler(CommandHandler("anomaly", cmd_anomaly))
    # Fix #3: global error handler
    application.add_error_handler(on_error)
    return application


def main() -> None:
    """Console entry point — starts long-polling against Telegram."""
    settings = AgentSettings()
    token = settings.telegram_bot_token
    if not token:
        logger.error(
            "TELEGRAM_BOT_TOKEN is not set. Get one from @BotFather, put it in "
            "agent/.env as TELEGRAM_BOT_TOKEN=..., then re-run. See agent/.env.example."
        )
        sys.exit(1)

    # Fail fast with a friendly message if the snapshot was never built.
    try:
        bot_data.load_snapshot()
    except FileNotFoundError as exc:
        logger.error(str(exc))
        sys.exit(1)

    logger.info("Starting SGSMM Telegram bot (long-polling)…")
    application = build_application(token)
    # Fix #4: only handle MESSAGE updates — all handlers are command-based
    application.run_polling(allowed_updates=[Update.MESSAGE])


if __name__ == "__main__":
    main()
