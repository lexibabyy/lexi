import numpy as np
import pandas as pd

from src import indicators


def test_ema_matches_pandas():
    s = pd.Series([1, 2, 3, 4, 5], dtype=float)
    expected = s.ewm(span=3, adjust=False).mean()
    pd.testing.assert_series_equal(indicators.ema(s, 3), expected)


def test_rsi_bounds():
    # Strictly rising series -> RSI should pin near 100.
    s = pd.Series(np.arange(1, 50), dtype=float)
    r = indicators.rsi(s, 14)
    assert r.iloc[-1] > 99.0
    assert (r <= 100.0).all()
    assert (r >= 0.0).all()


def test_rsi_falling():
    s = pd.Series(np.arange(50, 1, -1), dtype=float)
    r = indicators.rsi(s, 14)
    assert r.iloc[-1] < 1.0


def test_atr_positive():
    df = pd.DataFrame({
        "high": np.linspace(10, 20, 30) + 0.5,
        "low": np.linspace(10, 20, 30) - 0.5,
        "close": np.linspace(10, 20, 30),
    })
    a = indicators.atr(df, 14)
    assert (a.dropna() > 0).all()
