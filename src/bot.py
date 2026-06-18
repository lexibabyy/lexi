"""The trading bot orchestrator.

Pulls data, asks the strategy for a signal, applies risk management and
(unless in dry-run) sends orders to MT5 on a fixed polling interval. The
bot only acts on a newly closed candle so it evaluates each bar once.
"""
from __future__ import annotations

import logging
import time

from .config import Config
from .mt5_client import MT5Client, MT5Error
from .notifier import Notifier
from .risk import DailyLossGuard, calculate_lot
from .strategy import Signal, SignalType, build_strategy

log = logging.getLogger(__name__)


class TradingBot:
    def __init__(self, config: Config, client: MT5Client, notifier: Notifier | None = None):
        self.cfg = config
        self.client = client
        self.notifier = notifier or Notifier()
        self.strategy = build_strategy(config.strategy, config.risk.atr_period)
        self.guard = DailyLossGuard(config.risk)
        self._last_bar_time = None
        self._running = False

    def _notify(self, text: str) -> None:
        try:
            self.notifier.send(text)
        except Exception:  # never let a notification crash the loop
            log.exception("Notifier failed")

    def run(self) -> None:
        self._running = True
        mode = "DRY-RUN (no live orders)" if self.cfg.runtime.dry_run else "LIVE"
        log.info("Bot started in %s mode on %s %s",
                 mode, self.cfg.trading.symbol, self.cfg.trading.timeframe)
        try:
            while self._running:
                try:
                    self._tick()
                except MT5Error as exc:
                    log.error("MT5 error during tick: %s", exc)
                except Exception:  # keep the loop alive on unexpected errors
                    log.exception("Unexpected error during tick")
                time.sleep(self.cfg.trading.poll_interval_seconds)
        except KeyboardInterrupt:
            log.info("Interrupt received, shutting down...")
        finally:
            self.stop()

    def stop(self) -> None:
        self._running = False

    # ------------------------------------------------------------------
    def _tick(self) -> None:
        df = self.client.get_rates(self.cfg.strategy.history_bars)

        # The last fully-closed bar is index -2; only evaluate once per bar.
        closed_bar_time = df["time"].iloc[-2]
        if self._last_bar_time is not None and closed_bar_time == self._last_bar_time:
            return
        self._last_bar_time = closed_bar_time

        account = self.client.account_info()
        self.guard.update_day(account.balance)

        signal = self.strategy.generate(df)
        log.info("Bar %s | signal=%s (%s)",
                 closed_bar_time, signal.type.value, signal.reason)

        if signal.type == SignalType.HOLD:
            return

        positions = self.client.open_positions()

        # If we already hold a position in the opposite direction, close it
        # before considering a new entry (simple reverse-on-signal logic).
        self._maybe_close_opposite(positions, signal)

        if len(self.client.open_positions()) >= self.cfg.trading.max_open_positions:
            log.info("Max open positions reached; skipping entry.")
            return

        if not self.guard.can_trade(account.equity):
            return

        self._open_trade(signal, account.equity)

    def _maybe_close_opposite(self, positions, signal: Signal) -> None:
        import MetaTrader5 as mt5  # local import: only needed when live

        for pos in positions:
            is_buy = pos.type == mt5.POSITION_TYPE_BUY
            opposite = (is_buy and signal.type == SignalType.SELL) or (
                not is_buy and signal.type == SignalType.BUY
            )
            if not opposite:
                continue
            if self.cfg.runtime.dry_run:
                log.info("[DRY-RUN] Would close position %s on opposite signal", pos.ticket)
            else:
                self.client.close_position(pos)
                self._notify(
                    f"⚪️ Closed #{pos.ticket} on opposite signal "
                    f"(P/L {pos.profit:+.2f})"
                )

    def _open_trade(self, signal: Signal, equity: float) -> None:
        symbol_info = self.client.symbol_info()
        tick = self.client.tick()
        point = symbol_info.point

        atr_value = signal.atr or 0.0
        if atr_value <= 0:
            log.warning("ATR unavailable; skipping trade to avoid undefined risk.")
            return

        sl_distance = atr_value * self.cfg.risk.stop_loss_atr_mult
        tp_distance = atr_value * self.cfg.risk.take_profit_atr_mult

        if signal.type == SignalType.BUY:
            entry = tick.ask
            sl = entry - sl_distance
            tp = entry + tp_distance
        else:
            entry = tick.bid
            sl = entry + sl_distance
            tp = entry - tp_distance

        lot = calculate_lot(self.cfg.risk, equity, sl_distance, symbol_info)

        sl = round(sl, symbol_info.digits)
        tp = round(tp, symbol_info.digits)

        if self.cfg.runtime.dry_run:
            log.info(
                "[DRY-RUN] Would %s %.2f lots @ %.5f sl=%.5f tp=%.5f (risk %.2f%%)",
                signal.type.value.upper(), lot, entry, sl, tp,
                self.cfg.risk.risk_per_trade_pct,
            )
            self._notify(
                f"🧪 <b>[DRY-RUN]</b> Would {signal.type.value.upper()} "
                f"{lot} {self.cfg.trading.symbol} @ {entry:.5f}\n"
                f"SL {sl:.5f} | TP {tp:.5f}\n<i>{signal.reason}</i>"
            )
            return

        self.client.send_market_order(
            side=signal.type.value,
            volume=lot,
            sl=sl,
            tp=tp,
            comment=f"ema_rsi {signal.reason}"[:31],
        )
        emoji = "🟢" if signal.type == SignalType.BUY else "🔴"
        self._notify(
            f"{emoji} <b>{signal.type.value.upper()} {self.cfg.trading.symbol}</b>\n"
            f"{lot} lots @ {entry:.5f}\n"
            f"SL {sl:.5f} | TP {tp:.5f}\n<i>{signal.reason}</i>"
        )
