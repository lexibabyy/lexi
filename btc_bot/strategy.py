"""Strategy engine: structure-confirmed entries that scale into WINNERS only.

Flow per trade idea:
  Entry 1  : confidence >= 80 + HTF trend aligned + volatility ok
  Entry 2-4: ONLY while the position is in profit AND a fresh in-trend BOS
             prints AND the 2% cycle-risk budget allows. Never averages down.
  Exits    : TP1 1R / TP2 2R / TP3 3R (25% each), remainder trailed.
             Stop moves to breakeven after TP1.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import pandas as pd

from . import indicators as ind
from . import structure as struct
from . import confidence as conf


@dataclass
class Action:
    kind: str            # 'open' | 'add' | 'reduce' | 'close' | 'move_stop'
    qty: float = 0.0
    price: float = 0.0
    stop: float = 0.0
    info: str = ""


@dataclass
class TradeIdea:
    side: str                       # 'long' | 'short'
    avg_entry: float
    qty: float
    stop: float
    risk_per_unit: float            # |entry - stop| at inception (1R)
    tp_prices: list
    tp_filled: list = field(default_factory=lambda: [False, False, False])
    be_moved: bool = False
    n_entries: int = 1
    confidence: float = 0.0
    realized: float = 0.0


class StrategyEngine:
    def __init__(self, settings, risk):
        self.s = settings
        self.risk = risk
        self.idea: TradeIdea | None = None

    # ---------------------------------------------------------------- public
    def process(self, df: pd.DataFrame, htf_trend: str) -> list:
        """df = structure/entry timeframe OHLCV; htf_trend in {up,down,none}."""
        price = float(df["close"].iloc[-1])
        if self.idea is None:
            return self._try_enter(df, htf_trend, price)
        return self._manage(df, htf_trend, price)

    # --------------------------------------------------------------- entries
    def _volatility_ok(self, df: pd.DataFrame, price: float) -> bool:
        a = ind.atr(df, 14).iloc[-1]
        if price <= 0 or pd.isna(a):
            return False
        atr_pct = a / price
        return self.s.min_atr_pct <= atr_pct <= self.s.max_atr_pct

    def _try_enter(self, df: pd.DataFrame, htf_trend: str, price: float) -> list:
        ok, _ = self.risk.can_open_new_idea()
        if not ok or not self._volatility_ok(df, price):
            return []

        st = struct.analyze(df, self.s.swing_lookback)
        rsi = ind.rsi(df["close"])
        div = ind.rsi_divergence(df, rsi)
        vol = ind.volume_confirmation(df)

        side = "none"
        if htf_trend == "up":
            side = "long"
        elif htf_trend == "down":
            side = "short"
        if side == "none":
            return []

        if side == "long":
            c = conf.score(
                "long",
                liquidity_sweep=st.sweep == "bullish",
                rsi_divergence=div == "bullish",
                choch=st.choch == "bullish",
                bos=st.bos == "bullish",
                volume=vol,
            )
            stop = st.last_low
        else:
            c = conf.score(
                "short",
                liquidity_sweep=st.sweep == "bearish",
                rsi_divergence=div == "bearish",
                choch=st.choch == "bearish",
                bos=st.bos == "bearish",
                volume=vol,
            )
            stop = st.last_high

        if not c.passes or pd.isna(stop) or stop == 0:
            return []
        if (side == "long" and stop >= price) or (side == "short" and stop <= price):
            return []

        qty = self.risk.position_size(price, stop)
        if qty <= 0:
            return []

        r = abs(price - stop)
        sign = 1 if side == "long" else -1
        tps = [price + sign * lvl * r for lvl in self.s.tp_levels]

        self.risk.open_cycle()
        self.risk.register_entry()
        self.idea = TradeIdea(side, price, qty, stop, r, tps, confidence=c.score)
        return [Action("open", qty=qty, price=price, stop=stop,
                       info=f"{side} conf={c.score:.0f} {c.detail}")]

    # ---------------------------------------------------------------- manage
    def _manage(self, df: pd.DataFrame, htf_trend: str, price: float) -> list:
        idea = self.idea
        actions: list = []
        long = idea.side == "long"

        # 1) Stop loss
        if (long and price <= idea.stop) or (not long and price >= idea.stop):
            actions.append(self._close(price, "stop"))
            return actions

        # 2) Take-profit ladder
        for i, tp in enumerate(idea.tp_prices):
            if idea.tp_filled[i]:
                continue
            hit = (long and price >= tp) or (not long and price <= tp)
            if hit:
                chunk = idea.qty * self.s.tp_fraction
                idea.tp_filled[i] = True
                idea.realized += (tp - idea.avg_entry) * (1 if long else -1) * chunk
                idea.qty -= chunk
                actions.append(Action("reduce", qty=chunk, price=tp,
                                      info=f"TP{i + 1}"))
                if i == 0 and not idea.be_moved:        # breakeven after TP1
                    idea.stop = idea.avg_entry
                    idea.be_moved = True
                    actions.append(Action("move_stop", stop=idea.stop, info="BE"))

        # 3) Trail the runner after TP3
        if all(idea.tp_filled):
            a = ind.atr(df, 14).iloc[-1]
            trail = price - a if long else price + a
            if (long and trail > idea.stop) or (not long and trail < idea.stop):
                idea.stop = float(trail)
                actions.append(Action("move_stop", stop=idea.stop, info="trail"))

        # 4) Scale into WINNERS only (entries 2-4)
        if idea.n_entries < 4 and self._in_profit(price) and not all(idea.tp_filled):
            if self.risk.can_add_entry(self.s.risk_per_entry):
                st = struct.analyze(df, self.s.swing_lookback)
                fresh_bos = (long and st.bos == "bullish") or (not long and st.bos == "bearish")
                aligned = (long and htf_trend == "up") or (not long and htf_trend == "down")
                if fresh_bos and aligned:
                    add_qty = self.risk.position_size(price, idea.stop)
                    if add_qty > 0:
                        new_total = idea.qty + add_qty
                        idea.avg_entry = (idea.avg_entry * idea.qty + price * add_qty) / new_total
                        idea.qty = new_total
                        idea.n_entries += 1
                        self.risk.register_entry()
                        actions.append(Action("add", qty=add_qty, price=price,
                                              info=f"entry#{idea.n_entries}"))

        if idea.qty <= 1e-12:
            actions.append(self._close(price, "all TPs filled"))
        return actions

    def _in_profit(self, price: float) -> bool:
        idea = self.idea
        return price > idea.avg_entry if idea.side == "long" else price < idea.avg_entry

    def _close(self, price: float, reason: str) -> Action:
        idea = self.idea
        sign = 1 if idea.side == "long" else -1
        pnl = idea.realized + (price - idea.avg_entry) * sign * idea.qty
        self.last_close = {
            "side": idea.side, "avg_entry": idea.avg_entry, "exit": price,
            "pnl": pnl, "entries": idea.n_entries, "confidence": idea.confidence,
            "r_multiple": (pnl / (idea.risk_per_unit * max(idea.qty, 1e-9))),
            "reason": reason,
        }
        self.idea = None
        return Action("close", price=price, info=reason)
