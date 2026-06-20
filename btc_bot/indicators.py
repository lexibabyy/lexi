"""Technical indicators: EMA, RSI, ATR, RSI divergence, volume confirmation.

All functions take a pandas DataFrame with columns:
['open', 'high', 'low', 'close', 'volume'] indexed by time.
"""
from __future__ import annotations

import numpy as np
import pandas as pd


def ema(series: pd.Series, period: int) -> pd.Series:
    return series.ewm(span=period, adjust=False).mean()


def rsi(close: pd.Series, period: int = 14) -> pd.Series:
    delta = close.diff()
    gain = delta.clip(lower=0.0)
    loss = -delta.clip(upper=0.0)
    avg_gain = gain.ewm(alpha=1 / period, adjust=False).mean()
    avg_loss = loss.ewm(alpha=1 / period, adjust=False).mean()
    rs = avg_gain / avg_loss.replace(0.0, np.nan)
    out = 100 - (100 / (1 + rs))
    return out.fillna(50.0)


def atr(df: pd.DataFrame, period: int = 14) -> pd.Series:
    high, low, close = df["high"], df["low"], df["close"]
    prev_close = close.shift(1)
    tr = pd.concat(
        [(high - low), (high - prev_close).abs(), (low - prev_close).abs()],
        axis=1,
    ).max(axis=1)
    return tr.ewm(alpha=1 / period, adjust=False).mean()


def volume_confirmation(df: pd.DataFrame, period: int = 20, mult: float = 1.3) -> bool:
    """True if the latest bar's volume is meaningfully above its average."""
    if len(df) < period + 1:
        return False
    vol = df["volume"]
    avg = vol.rolling(period).mean().iloc[-1]
    return bool(vol.iloc[-1] >= mult * avg)


def rsi_divergence(df: pd.DataFrame, rsi_series: pd.Series, lookback: int = 40):
    """Detect classic RSI divergence on the last two swing extremes.

    Returns 'bullish', 'bearish' or None.
      bullish: price makes a lower low, RSI makes a higher low.
      bearish: price makes a higher high, RSI makes a lower high.
    """
    if len(df) < lookback + 5:
        return None
    window = df.iloc[-lookback:]
    rsi_w = rsi_series.iloc[-lookback:]
    lows = window["low"]
    highs = window["high"]

    # two most recent local lows / highs (simple argpartition on halves)
    half = lookback // 2
    l1 = lows.iloc[:half].idxmin()
    l2 = lows.iloc[half:].idxmin()
    h1 = highs.iloc[:half].idxmax()
    h2 = highs.iloc[half:].idxmax()

    if lows[l2] < lows[l1] and rsi_w[l2] > rsi_w[l1]:
        return "bullish"
    if highs[h2] > highs[h1] and rsi_w[h2] < rsi_w[h1]:
        return "bearish"
    return None
