"""Exchange layer: ccxt adapter (Binance / Bybit, testnet) + a PaperBroker.

Keys are read from Settings (env vars). In 'paper' mode no keys are needed
and all fills are simulated locally.
"""
from __future__ import annotations

import time

import pandas as pd

try:
    import ccxt
except ImportError:        # allow import without ccxt for offline unit tests
    ccxt = None


class ExchangeClient:
    """Thin ccxt wrapper for market data and order placement."""

    def __init__(self, settings):
        self.s = settings
        self.ex = None
        if settings.mode in ("testnet", "live") and ccxt is not None:
            klass = getattr(ccxt, settings.exchange)
            self.ex = klass({
                "apiKey": settings.api_key,
                "secret": settings.api_secret,
                "enableRateLimit": True,
                "options": {"defaultType": "swap"},
            })
            if settings.mode == "testnet":
                self.ex.set_sandbox_mode(True)
        elif ccxt is not None:
            # public data only (paper mode)
            self.ex = getattr(ccxt, settings.exchange)({"enableRateLimit": True})

    def fetch_ohlcv(self, timeframe: str, limit: int = 300) -> pd.DataFrame:
        rows = self.ex.fetch_ohlcv(self.s.symbol, timeframe=timeframe, limit=limit)
        df = pd.DataFrame(rows, columns=["ts", "open", "high", "low", "close", "volume"])
        df["ts"] = pd.to_datetime(df["ts"], unit="ms")
        return df.set_index("ts")

    def spread_pct(self) -> float:
        t = self.ex.fetch_ticker(self.s.symbol)
        bid, ask = t.get("bid"), t.get("ask")
        if not bid or not ask:
            return 0.0
        return (ask - bid) / ((ask + bid) / 2)

    def market_order(self, side: str, qty: float):
        if self.s.mode == "paper":
            raise RuntimeError("market_order called in paper mode")
        return self.ex.create_order(self.s.symbol, "market", side, qty)


class PaperBroker:
    """Simulated broker for paper trading and backtests."""

    def __init__(self, equity: float):
        self.equity = equity
        self.position_qty = 0.0      # signed: +long / -short
        self.avg_price = 0.0

    def fill(self, side: str, qty: float, price: float) -> None:
        signed = qty if side == "buy" else -qty
        new_qty = self.position_qty + signed
        if self.position_qty == 0 or (self.position_qty > 0) == (signed > 0):
            # opening or increasing
            if new_qty != 0:
                self.avg_price = (
                    self.avg_price * abs(self.position_qty) + price * abs(signed)
                ) / abs(new_qty)
        else:
            # reducing / closing: realise pnl on the closed part
            closed = min(abs(signed), abs(self.position_qty))
            direction = 1 if self.position_qty > 0 else -1
            self.equity += (price - self.avg_price) * direction * closed
        self.position_qty = new_qty
        if abs(self.position_qty) < 1e-12:
            self.position_qty = 0.0
            self.avg_price = 0.0

    def mark_to_market(self, price: float) -> float:
        if self.position_qty == 0:
            return self.equity
        direction = 1 if self.position_qty > 0 else -1
        return self.equity + (price - self.avg_price) * direction * abs(self.position_qty)
