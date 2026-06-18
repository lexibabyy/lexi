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
    symbol: str = "XAUUSD"
    timeframe: str = "M5"
    magic_number: int = 532023
    deviation: int = 30
    poll_interval_seconds: int = 15
    max_open_positions: int = 5


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
class EntriesConfig:
    # Keep adding entries in the prevailing trend direction (scale in)
    # instead of taking a single trade per crossover.
    pyramid: bool = True
    # Minimum number of closed bars between added entries, so the bot
    # spaces its entries out instead of stacking them all on one bar.
    spacing_bars: int = 3
    # If True, close opposite-direction positions when the signal flips.
    # Off by default for the scale-in + take-profit style.
    reverse_on_opposite: bool = False


@dataclass
class ExitConfig:
    # Core behaviour you asked for: as soon as a position has earnings,
    # close it. A small minimum clears spread/commission so we don't
    # close for a fraction of a cent.
    close_in_profit: bool = True
    # Minimum floating profit (in account currency) before a single
    # position is closed.
    min_profit_money: float = 0.50
    # If > 0, close EVERY open position at once when their combined
    # floating profit reaches this amount (account currency). 0 disables.
    basket_profit_money: float = 0.0


@dataclass
class RuntimeConfig:
    dry_run: bool = True
    log_level: str = "INFO"
    log_file: str = "bot.log"


@dataclass
class TelegramConfig:
    enabled: bool = False
    token: Optional[str] = None
    # Your personal chat id. Only this chat may control the bot and it is
    # where alerts are sent.
    chat_id: Optional[str] = None
    # If true, the bot's auto-trading loop does NOT start on launch; you
    # start it from your phone with /run. Recommended.
    start_paused: bool = True


@dataclass
class Config:
    account: AccountConfig = field(default_factory=AccountConfig)
    trading: TradingConfig = field(default_factory=TradingConfig)
    risk: RiskConfig = field(default_factory=RiskConfig)
    strategy: StrategyConfig = field(default_factory=StrategyConfig)
    entries: EntriesConfig = field(default_factory=EntriesConfig)
    exit: ExitConfig = field(default_factory=ExitConfig)
    runtime: RuntimeConfig = field(default_factory=RuntimeConfig)
    telegram: TelegramConfig = field(default_factory=TelegramConfig)

    @staticmethod
    def load(path: str = "config.yaml") -> "Config":
        with open(path, "r", encoding="utf-8") as fh:
            raw = yaml.safe_load(fh) or {}

        cfg = Config(
            account=AccountConfig(**(raw.get("account") or {})),
            trading=TradingConfig(**(raw.get("trading") or {})),
            risk=RiskConfig(**(raw.get("risk") or {})),
            strategy=StrategyConfig(**(raw.get("strategy") or {})),
            entries=EntriesConfig(**(raw.get("entries") or {})),
            exit=ExitConfig(**(raw.get("exit") or {})),
            runtime=RuntimeConfig(**(raw.get("runtime") or {})),
            telegram=TelegramConfig(**(raw.get("telegram") or {})),
        )

        # Environment variables override file values for secrets so
        # credentials never need to live on disk.
        if os.getenv("MT5_LOGIN"):
            cfg.account.login = int(os.environ["MT5_LOGIN"])
        if os.getenv("MT5_PASSWORD"):
            cfg.account.password = os.environ["MT5_PASSWORD"]
        if os.getenv("MT5_SERVER"):
            cfg.account.server = os.environ["MT5_SERVER"]
        if os.getenv("TELEGRAM_TOKEN"):
            cfg.telegram.token = os.environ["TELEGRAM_TOKEN"]
            cfg.telegram.enabled = True
        if os.getenv("TELEGRAM_CHAT_ID"):
            cfg.telegram.chat_id = os.environ["TELEGRAM_CHAT_ID"]

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
