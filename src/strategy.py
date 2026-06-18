"""Signal-generation strategies.

A strategy consumes a candle DataFrame and emits a Signal. The default
``EmaRsiStrategy`` goes long when the fast EMA crosses above the slow EMA
while RSI is not overbought, and short on the opposite crossover while RSI
is not oversold. Swap in your own by subclassing ``Strategy``.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from enum import Enum
from typing import Optional

import pandas as pd

from . import indicators
from .config import StrategyConfig

log = logging.getLogger(__name__)


class SignalType(Enum):
    BUY = "buy"
    SELL = "sell"
    HOLD = "hold"


@dataclass
class Signal:
    type: SignalType
    reason: str = ""
    atr: Optional[float] = None


class Strategy:
    def generate(self, df: pd.DataFrame) -> Signal:  # pragma: no cover - interface
        raise NotImplementedError


class EmaRsiStrategy(Strategy):
    def __init__(self, cfg: StrategyConfig, atr_period: int):
        self.cfg = cfg
        self.atr_period = atr_period

    def generate(self, df: pd.DataFrame) -> Signal:
        needed = max(self.cfg.slow_ema, self.cfg.rsi_period, self.atr_period) + 2
        if len(df) < needed:
            return Signal(SignalType.HOLD, reason="not enough history")

        close = df["close"]
        fast = indicators.ema(close, self.cfg.fast_ema)
        slow = indicators.ema(close, self.cfg.slow_ema)
        rsi = indicators.rsi(close, self.cfg.rsi_period)
        atr_series = indicators.atr(df, self.atr_period)

        # Use the last CLOSED candle (index -2) to avoid acting on a
        # still-forming bar that can repaint.
        i = -2
        fast_now, fast_prev = fast.iloc[i], fast.iloc[i - 1]
        slow_now, slow_prev = slow.iloc[i], slow.iloc[i - 1]
        rsi_now = rsi.iloc[i]
        atr_now = float(atr_series.iloc[i])

        crossed_up = fast_prev <= slow_prev and fast_now > slow_now
        crossed_down = fast_prev >= slow_prev and fast_now < slow_now

        if crossed_up and rsi_now < self.cfg.rsi_overbought:
            return Signal(
                SignalType.BUY,
                reason=f"EMA cross up (rsi={rsi_now:.1f})",
                atr=atr_now,
            )
        if crossed_down and rsi_now > self.cfg.rsi_oversold:
            return Signal(
                SignalType.SELL,
                reason=f"EMA cross down (rsi={rsi_now:.1f})",
                atr=atr_now,
            )

        return Signal(SignalType.HOLD, reason="no crossover", atr=atr_now)


def build_strategy(cfg: StrategyConfig, atr_period: int) -> Strategy:
    if cfg.name == "ema_rsi":
        return EmaRsiStrategy(cfg, atr_period)
    raise ValueError(f"Unknown strategy: {cfg.name}")
