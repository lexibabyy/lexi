"""Position sizing and risk controls.

The position sizer converts a percentage-of-equity risk budget plus a
stop-loss distance into a broker-valid lot size. The daily-loss guard
prevents the bot from trading after a defined drawdown.
"""
from __future__ import annotations

import logging
from datetime import date

from .config import RiskConfig

log = logging.getLogger(__name__)


def _round_to_step(volume: float, step: float) -> float:
    if step <= 0:
        return volume
    return round(round(volume / step) * step, 8)


def calculate_lot(
    cfg: RiskConfig,
    equity: float,
    stop_loss_points: float,
    symbol_info,
) -> float:
    """Return a lot size such that hitting the stop loses ~risk_per_trade_pct.

    ``stop_loss_points`` is the SL distance expressed in *price points*
    (i.e. price units, not pips). We use the broker's tick value/size to
    translate that into monetary loss per lot.
    """
    if stop_loss_points <= 0:
        return cfg.min_lot

    risk_amount = equity * (cfg.risk_per_trade_pct / 100.0)

    tick_value = getattr(symbol_info, "trade_tick_value", 0.0) or 0.0
    tick_size = getattr(symbol_info, "trade_tick_size", 0.0) or 0.0
    if tick_value <= 0 or tick_size <= 0:
        log.warning("Missing tick value/size; falling back to min_lot.")
        return cfg.min_lot

    # Money lost per 1.0 lot if price moves by stop_loss_points.
    loss_per_lot = (stop_loss_points / tick_size) * tick_value
    if loss_per_lot <= 0:
        return cfg.min_lot

    raw_lot = risk_amount / loss_per_lot

    step = getattr(symbol_info, "volume_step", 0.01) or 0.01
    broker_min = getattr(symbol_info, "volume_min", cfg.min_lot) or cfg.min_lot
    broker_max = getattr(symbol_info, "volume_max", cfg.max_lot) or cfg.max_lot

    lot = _round_to_step(raw_lot, step)
    lot = max(lot, cfg.min_lot, broker_min)
    lot = min(lot, cfg.max_lot, broker_max)
    return lot


class DailyLossGuard:
    """Stops new trades once the daily loss limit is breached."""

    def __init__(self, cfg: RiskConfig):
        self.cfg = cfg
        self._day: date | None = None
        self._start_balance: float | None = None

    def update_day(self, balance: float) -> None:
        today = date.today()
        if self._day != today:
            self._day = today
            self._start_balance = balance
            log.info("New trading day. Start balance = %.2f", balance)

    def can_trade(self, equity: float) -> bool:
        if self._start_balance is None:
            return True
        loss_pct = (self._start_balance - equity) / self._start_balance * 100.0
        if loss_pct >= self.cfg.max_daily_loss_pct:
            log.warning(
                "Daily loss limit hit (%.2f%% >= %.2f%%). No new trades today.",
                loss_pct, self.cfg.max_daily_loss_pct,
            )
            return False
        return True
