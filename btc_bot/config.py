"""Central configuration. API keys come from environment variables only."""
from __future__ import annotations

import os
from dataclasses import dataclass, field


@dataclass
class Settings:
    # --- Market ---
    exchange: str = os.getenv("EXCHANGE", "binance")     # binance | bybit
    symbol: str = os.getenv("SYMBOL", "BTC/USDT")
    # Timeframes (HTF trend / structure / entry / confirmation)
    tf_htf: str = "4h"
    tf_structure: str = "1h"
    tf_entry: str = "15m"
    tf_confirm: str = "5m"

    # --- Mode & keys ---
    mode: str = os.getenv("TRADING_MODE", "paper")        # paper | testnet | live
    api_key: str = os.getenv("API_KEY", "")
    api_secret: str = os.getenv("API_SECRET", "")

    # --- Account ---
    start_equity: float = float(os.getenv("START_EQUITY", "1000"))

    # --- Confidence ---
    min_confidence: float = 80.0

    # --- Risk (fractions of equity) ---
    risk_per_entry: float = 0.005     # 0.5%
    max_cycle_risk: float = 0.02      # 2% per trade idea (4 x 0.5%)
    max_daily_dd: float = 0.03        # 3%
    max_weekly_dd: float = 0.08       # 8%
    emergency_dd: float = 0.10        # 10% -> hard stop
    max_consecutive_losses: int = 3

    # --- Volatility / sanity filters ---
    max_atr_pct: float = 0.05         # skip if ATR > 5% of price (too wild)
    min_atr_pct: float = 0.0008       # skip if ATR < 0.08% of price (dead)
    max_spread_pct: float = 0.0010    # skip if spread > 0.10%

    # --- Take profit ladder (R multiples, fraction closed at each) ---
    tp_levels: tuple = field(default=(1.0, 2.0, 3.0))
    tp_fraction: float = 0.25         # close 25% at TP1, TP2, TP3; trail rest

    # --- Structure detection ---
    swing_lookback: int = 3           # fractal half-window for swings

    @property
    def is_live(self) -> bool:
        return self.mode == "live"


SETTINGS = Settings()
