"""Configuration loading and validation."""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Optional

import yaml


@dataclass
class AccountConfig:
    login: Optional[int] = None
    password: Optional[str] = None
    server: Optional[str] = None
    terminal_path: Optional[str] = None


@dataclass
class TradingConfig:
    symbol: str = "EURUSD"
    timeframe: str = "M5"
    magic_number: int = 532023
    deviation: int = 20
    poll_interval_seconds: int = 15
    max_open_positions: int = 1


@dataclass
class RiskConfig:
    risk_per_trade_pct: float = 1.0
    atr_period: int = 14
    stop_loss_atr_mult: float = 1.5
    take_profit_atr_mult: float = 3.0
    min_lot: float = 0.01
    max_lot: float = 1.0
    max_daily_loss_pct: float = 5.0


@dataclass
class StrategyConfig:
    name: str = "ema_rsi"
    fast_ema: int = 12
    slow_ema: int = 26
    rsi_period: int = 14
    rsi_overbought: float = 70.0
    rsi_oversold: float = 30.0
    history_bars: int = 500


@dataclass
class RuntimeConfig:
    dry_run: bool = True
    log_level: str = "INFO"
    log_file: str = "bot.log"


@dataclass
class Config:
    account: AccountConfig = field(default_factory=AccountConfig)
    trading: TradingConfig = field(default_factory=TradingConfig)
    risk: RiskConfig = field(default_factory=RiskConfig)
    strategy: StrategyConfig = field(default_factory=StrategyConfig)
    runtime: RuntimeConfig = field(default_factory=RuntimeConfig)

    @staticmethod
    def load(path: str = "config.yaml") -> "Config":
        with open(path, "r", encoding="utf-8") as fh:
            raw = yaml.safe_load(fh) or {}

        cfg = Config(
            account=AccountConfig(**(raw.get("account") or {})),
            trading=TradingConfig(**(raw.get("trading") or {})),
            risk=RiskConfig(**(raw.get("risk") or {})),
            strategy=StrategyConfig(**(raw.get("strategy") or {})),
            runtime=RuntimeConfig(**(raw.get("runtime") or {})),
        )

        # Environment variables override file values for secrets so
        # credentials never need to live on disk.
        if os.getenv("MT5_LOGIN"):
            cfg.account.login = int(os.environ["MT5_LOGIN"])
        if os.getenv("MT5_PASSWORD"):
            cfg.account.password = os.environ["MT5_PASSWORD"]
        if os.getenv("MT5_SERVER"):
            cfg.account.server = os.environ["MT5_SERVER"]

        cfg.validate()
        return cfg

    def validate(self) -> None:
        if self.risk.risk_per_trade_pct <= 0:
            raise ValueError("risk_per_trade_pct must be > 0")
        if self.risk.min_lot <= 0 or self.risk.max_lot < self.risk.min_lot:
            raise ValueError("invalid lot bounds: min_lot must be > 0 and <= max_lot")
        if self.strategy.fast_ema >= self.strategy.slow_ema:
            raise ValueError("fast_ema must be smaller than slow_ema")
        if self.trading.poll_interval_seconds < 1:
            raise ValueError("poll_interval_seconds must be >= 1")
