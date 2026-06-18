"""Runtime controller for starting/stopping the bot from outside.

Wraps a :class:`TradingBot` so the trading loop runs in a background thread
while a separate caller (e.g. the Telegram handler on your phone) can start
it, stop it, and query/close positions safely.
"""
from __future__ import annotations

import logging
import threading

from .bot import TradingBot
from .config import Config
from .mt5_client import MT5Client

log = logging.getLogger(__name__)


class BotController:
    def __init__(self, config: Config, client: MT5Client, notifier=None):
        self.cfg = config
        self.client = client
        self.bot = TradingBot(config, client, notifier=notifier)
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------
    def is_running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def start(self) -> str:
        with self._lock:
            if self.is_running():
                return "Bot is already running."
            self._thread = threading.Thread(
                target=self.bot.run, name="trading-loop", daemon=True
            )
            self._thread.start()
            mode = "DRY-RUN" if self.cfg.runtime.dry_run else "LIVE"
            return f"▶️ Bot started ({mode}) on {self.cfg.trading.symbol} {self.cfg.trading.timeframe}."

    def stop(self) -> str:
        with self._lock:
            if not self.is_running():
                return "Bot is not running."
            self.bot.stop()
        self._thread.join(timeout=self.cfg.trading.poll_interval_seconds + 5)
        self._thread = None
        return "⏹️ Bot stopped. Open positions are left untouched."

    # ------------------------------------------------------------------
    # Queries / actions usable from the phone
    # ------------------------------------------------------------------
    def status_text(self) -> str:
        acc = self.client.account_info()
        positions = self.client.open_positions()
        state = "🟢 RUNNING" if self.is_running() else "🔴 STOPPED"
        mode = "DRY-RUN" if self.cfg.runtime.dry_run else "LIVE"
        return (
            f"<b>Status:</b> {state} ({mode})\n"
            f"<b>Symbol:</b> {self.cfg.trading.symbol} {self.cfg.trading.timeframe}\n"
            f"<b>Balance:</b> {acc.balance:.2f} {acc.currency}\n"
            f"<b>Equity:</b> {acc.equity:.2f} {acc.currency}\n"
            f"<b>Open positions:</b> {len(positions)}"
        )

    def positions_text(self) -> str:
        positions = self.client.open_positions()
        if not positions:
            return "No open positions."
        lines = ["<b>Open positions:</b>"]
        for p in positions:
            side = "BUY" if p.type == 0 else "SELL"
            lines.append(
                f"#{p.ticket} {side} {p.volume} @ {p.price_open:.5f} "
                f"| P/L {p.profit:+.2f}"
            )
        return "\n".join(lines)

    def close_all(self) -> str:
        positions = self.client.open_positions()
        if not positions:
            return "No open positions to close."
        closed, failed = 0, 0
        for p in positions:
            try:
                self.client.close_position(p)
                closed += 1
            except Exception as exc:  # report rather than crash
                log.warning("Failed to close %s: %s", p.ticket, exc)
                failed += 1
        msg = f"Closed {closed} position(s)."
        if failed:
            msg += f" {failed} failed."
        return msg
