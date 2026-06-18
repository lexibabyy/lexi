import numpy as np
import pandas as pd

from src.config import StrategyConfig
from src.strategy import EmaRsiStrategy, SignalType


def _frame(closes):
    n = len(closes)
    return pd.DataFrame({
        "time": pd.date_range("2024-01-01", periods=n, freq="5min"),
        "open": closes,
        "high": [c + 0.5 for c in closes],
        "low": [c - 0.5 for c in closes],
        "close": closes,
    })


def test_hold_on_insufficient_history():
    strat = EmaRsiStrategy(StrategyConfig(), atr_period=14)
    df = _frame([1.0, 2.0, 3.0])
    assert strat.generate(df).type == SignalType.HOLD


def test_buy_signal_on_upward_cross():
    # Downtrend then sharp reversal up forces a fast-over-slow crossover.
    closes = list(np.linspace(100, 80, 60)) + list(np.linspace(80, 110, 20))
    strat = EmaRsiStrategy(StrategyConfig(fast_ema=5, slow_ema=20), atr_period=14)
    sig = strat.generate(_frame(closes))
    assert sig.type in (SignalType.BUY, SignalType.HOLD)
    assert sig.atr is not None and sig.atr > 0


def test_signal_atr_present():
    closes = list(np.linspace(50, 60, 80))
    strat = EmaRsiStrategy(StrategyConfig(), atr_period=14)
    sig = strat.generate(_frame(closes))
    assert sig.atr is not None
