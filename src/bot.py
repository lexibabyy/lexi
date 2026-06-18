"""The trading bot orchestrator.

Pulls data, asks the strategy for a signal, applies risk management and
(unless in dry-run) sends orders to MT5 on a fixed polling interval. The
bot only acts on a newly closed candle so it evaluates each bar once.
"""
from __future__ import annotations

import logging
import time

from .config import Config
from .exits import select_profit_exits
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
        self._bars_since_entry = 10_000  # large so the first entry isn't blocked
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
        self._bars_since_entry += 1

        account = self.client.account_info()
        self.guard.update_day(account.balance)

        # 1) Bank earnings first: close any position that is in profit.
        self._take_profits()

        # 2) Decide whether to add a new entry.
        signal = self.strategy.generate(df)
        trend = self.strategy.trend(df)
        log.info("Bar %s | signal=%s trend=%+d (%s)",
                 closed_bar_time, signal.type.value, trend, signal.reason)

        fresh = signal.type if signal.type != SignalType.HOLD else None

        if fresh and self.cfg.entries.reverse_on_opposite:
            self._close_opposite(fresh)

        # Direction: a fresh crossover always counts; otherwise scale into
        # the prevailing trend if pyramiding is enabled.
        if fresh:
            direction = fresh
            is_pyramid = False
        elif self.cfg.entries.pyramid and trend != 0:
            direction = SignalType.BUY if trend > 0 else SignalType.SELL
            is_pyramid = True
        else:
            return

        # Space out added (pyramid) entries; the first/fresh entry is exempt.
        if is_pyramid and self._bars_since_entry < self.cfg.entries.spacing_bars:
            return

        if len(self.client.open_positions()) >= self.cfg.trading.max_open_positions:
            log.info("Max open positions (%d) reached; not adding more.",
                     self.cfg.trading.max_open_positions)
            return

        if not self.guard.can_trade(account.equity):
            return

        self._open_trade(direction, signal.atr, account.equity,
                         reason=signal.reason if fresh else "scale-in (trend)")

    def _take_profits(self) -> None:
        """Close positions that have earnings (the core requested behaviour)."""
        positions = self.client.open_positions()
        if not positions:
            return

        to_close, reason = select_profit_exits(
            positions,
            self.cfg.exit.min_profit_money,
            self.cfg.exit.basket_profit_money,
        )
        if not self.cfg.exit.close_in_profit and "basket" not in reason:
            return

        for pos in to_close:
            if self.cfg.runtime.dry_run:
                log.info("[DRY-RUN] Would close #%s (P/L %+.2f) — %s",
                         pos.ticket, pos.profit, reason)
                continue
            self.client.close_position(pos)
            self._notify(
                f"💰 Banked #{pos.ticket} (P/L {pos.profit:+.2f}) — {reason}"
            )

    def _close_opposite(self, direction: SignalType) -> None:
        import MetaTrader5 as mt5  # local import: only needed when live

        for pos in self.client.open_positions():
            is_buy = pos.type == mt5.POSITION_TYPE_BUY
            opposite = (is_buy and direction == SignalType.SELL) or (
                not is_buy and direction == SignalType.BUY
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

    def _open_trade(self, direction: SignalType, atr: float | None,
                    equity: float, reason: str) -> None:
        symbol_info = self.client.symbol_info()
        tick = self.client.tick()

        atr_value = atr or 0.0
        if atr_value <= 0:
            log.warning("ATR unavailable; skipping trade to avoid undefined risk.")
            return

        sl_distance = atr_value * self.cfg.risk.stop_loss_atr_mult
        tp_distance = atr_value * self.cfg.risk.take_profit_atr_mult

        if direction == SignalType.BUY:
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
                direction.value.upper(), lot, entry, sl, tp,
                self.cfg.risk.risk_per_trade_pct,
            )
            self._notify(
                f"🧪 <b>[DRY-RUN]</b> Would {direction.value.upper()} "
                f"{lot} {self.cfg.trading.symbol} @ {entry:.5f}\n"
                f"SL {sl:.5f} | TP {tp:.5f}\n<i>{reason}</i>"
            )
            self._bars_since_entry = 0
            return

        self.client.send_market_order(
            side=direction.value,
            volume=lot,
            sl=sl,
            tp=tp,
            comment=f"ema_rsi {reason}"[:31],
        )
        self._bars_since_entry = 0
        emoji = "🟢" if direction == SignalType.BUY else "🔴"
        self._notify(
            f"{emoji} <b>{direction.value.upper()} {self.cfg.trading.symbol}</b>\n"
            f"{lot} lots @ {entry:.5f}\n"
            f"SL {sl:.5f} | TP {tp:.5f}\n<i>{reason}</i>"
        )
