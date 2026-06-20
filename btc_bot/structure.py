"""Market-structure & Smart-Money-Concept detection (heuristic).

These are approximations of subjective ideas. They are deterministic and
testable, but they are NOT a perfect reading of "smart money". Treat the
outputs as confluence signals, not certainties.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import pandas as pd


@dataclass
class Swing:
    idx: int
    price: float
    kind: str          # 'high' or 'low'
    label: str = ""    # HH / HL / LH / LL


@dataclass
class StructureState:
    swings: list = field(default_factory=list)
    trend: str = "none"          # 'up' | 'down' | 'none'
    bos: str = "none"            # 'bullish' | 'bearish' | 'none'
    choch: str = "none"          # 'bullish' | 'bearish' | 'none'
    sweep: str = "none"          # 'bullish' | 'bearish' | 'none'
    fvg: str = "none"            # 'bullish' | 'bearish' | 'none'
    last_high: float = float("nan")
    last_low: float = float("nan")


def find_swings(df: pd.DataFrame, lookback: int = 3) -> list:
    """Fractal swing highs/lows: extreme within +/- lookback bars."""
    highs, lows = df["high"].values, df["low"].values
    n = len(df)
    swings = []
    for i in range(lookback, n - lookback):
        win_h = highs[i - lookback:i + lookback + 1]
        win_l = lows[i - lookback:i + lookback + 1]
        if highs[i] == win_h.max() and (win_h.argmax() == lookback):
            swings.append(Swing(i, float(highs[i]), "high"))
        elif lows[i] == win_l.min() and (win_l.argmin() == lookback):
            swings.append(Swing(i, float(lows[i]), "low"))
    return swings


def _label_swings(swings: list) -> None:
    last_high = last_low = None
    for s in swings:
        if s.kind == "high":
            s.label = "HH" if (last_high is not None and s.price > last_high) else "LH"
            last_high = s.price
        else:
            s.label = "HL" if (last_low is not None and s.price > last_low) else "LL"
            last_low = s.price


def analyze(df: pd.DataFrame, lookback: int = 3) -> StructureState:
    """Build a StructureState from a (structure-timeframe) DataFrame."""
    st = StructureState()
    swings = find_swings(df, lookback)
    if len(swings) < 3:
        return st
    _label_swings(swings)
    st.swings = swings

    highs = [s for s in swings if s.kind == "high"]
    lows = [s for s in swings if s.kind == "low"]
    if highs:
        st.last_high = highs[-1].price
    if lows:
        st.last_low = lows[-1].price

    # Trend from the two most recent highs and lows.
    if len(highs) >= 2 and len(lows) >= 2:
        up = highs[-1].price > highs[-2].price and lows[-1].price > lows[-2].price
        down = highs[-1].price < highs[-2].price and lows[-1].price < lows[-2].price
        st.trend = "up" if up else "down" if down else "none"

    close = float(df["close"].iloc[-1])

    # BOS: close breaks the most recent opposing swing in the trend direction.
    if highs and close > highs[-1].price:
        st.bos = "bullish"
    elif lows and close < lows[-1].price:
        st.bos = "bearish"

    # CHoCH: a break against the prevailing trend (character change).
    if st.trend == "down" and st.bos == "bullish":
        st.choch = "bullish"
    elif st.trend == "up" and st.bos == "bearish":
        st.choch = "bearish"

    st.sweep = _liquidity_sweep(df, swings)
    st.fvg = _fair_value_gap(df)
    return st


def _liquidity_sweep(df: pd.DataFrame, swings: list):
    """Wick beyond a prior swing then close back inside = stop hunt / sweep."""
    if len(df) < 2 or len(swings) < 2:
        return "none"
    last = df.iloc[-1]
    lows = [s for s in swings[:-1] if s.kind == "low"]
    highs = [s for s in swings[:-1] if s.kind == "high"]
    if lows and last["low"] < lows[-1].price and last["close"] > lows[-1].price:
        return "bullish"
    if highs and last["high"] > highs[-1].price and last["close"] < highs[-1].price:
        return "bearish"
    return "none"


def _fair_value_gap(df: pd.DataFrame):
    """3-candle imbalance on the last completed triple."""
    if len(df) < 3:
        return "none"
    a, c = df.iloc[-3], df.iloc[-1]
    if c["low"] > a["high"]:
        return "bullish"
    if c["high"] < a["low"]:
        return "bearish"
    return "none"
