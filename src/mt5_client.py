"""Thin wrapper around the MetaTrader5 terminal API.

Centralises connection handling, data fetching and order execution so
the rest of the bot never touches the raw ``MetaTrader5`` module
directly. This also makes the bot easy to unit-test by swapping this
client for a fake.
"""
from __future__ import annotations

import logging
from typing import Optional

import pandas as pd

try:
    import MetaTrader5 as mt5
except ImportError:  # pragma: no cover - import guard for non-Windows dev boxes
    mt5 = None

from .config import Config

log = logging.getLogger(__name__)

# Map human-friendly timeframe strings to MT5 constants. Resolved lazily
# because the constants only exist once the module is importable.
_TIMEFRAME_NAMES = {
    "M1": "TIMEFRAME_M1",
    "M5": "TIMEFRAME_M5",
    "M15": "TIMEFRAME_M15",
    "M30": "TIMEFRAME_M30",
    "H1": "TIMEFRAME_H1",
    "H4": "TIMEFRAME_H4",
    "D1": "TIMEFRAME_D1",
}


class MT5Error(RuntimeError):
    """Raised when an MT5 call fails."""


class MT5Client:
    def __init__(self, config: Config):
        if mt5 is None:
            raise MT5Error(
                "The 'MetaTrader5' package is not installed or unavailable on "
                "this platform. It only runs on Windows with the MT5 terminal."
            )
        self.cfg = config
        self._connected = False

    # ------------------------------------------------------------------
    # Connection lifecycle
    # ------------------------------------------------------------------
    def connect(self) -> None:
        acc = self.cfg.account
        init_kwargs = {}
        if acc.terminal_path:
            init_kwargs["path"] = acc.terminal_path
        if acc.login:
            init_kwargs.update(login=int(acc.login), password=acc.password, server=acc.server)

        if not mt5.initialize(**init_kwargs):
            raise MT5Error(f"initialize() failed: {mt5.last_error()}")

        # Make sure the symbol is visible in Market Watch.
        if not mt5.symbol_select(self.cfg.trading.symbol, True):
            raise MT5Error(
                f"Could not select symbol {self.cfg.trading.symbol}: {mt5.last_error()}"
            )

        self._connected = True
        info = mt5.account_info()
        if info is None:
            raise MT5Error(f"account_info() returned None: {mt5.last_error()}")
        log.info(
            "Connected to MT5 | account=%s server=%s balance=%.2f %s",
            info.login, info.server, info.balance, info.currency,
        )

    def shutdown(self) -> None:
        if self._connected:
            mt5.shutdown()
            self._connected = False
            log.info("MT5 connection closed.")

    # ------------------------------------------------------------------
    # Market data
    # ------------------------------------------------------------------
    def _timeframe(self) -> int:
        name = self.cfg.trading.timeframe.upper()
        if name not in _TIMEFRAME_NAMES:
            raise MT5Error(f"Unsupported timeframe: {name}")
        return getattr(mt5, _TIMEFRAME_NAMES[name])

    def get_rates(self, bars: int) -> pd.DataFrame:
        """Return the most recent ``bars`` candles as a DataFrame."""
        rates = mt5.copy_rates_from_pos(
            self.cfg.trading.symbol, self._timeframe(), 0, bars
        )
        if rates is None or len(rates) == 0:
            raise MT5Error(f"No rate data returned: {mt5.last_error()}")
        df = pd.DataFrame(rates)
        df["time"] = pd.to_datetime(df["time"], unit="s")
        return df

    def symbol_info(self):
        info = mt5.symbol_info(self.cfg.trading.symbol)
        if info is None:
            raise MT5Error(f"symbol_info() failed: {mt5.last_error()}")
        return info

    def tick(self):
        tick = mt5.symbol_info_tick(self.cfg.trading.symbol)
        if tick is None:
            raise MT5Error(f"symbol_info_tick() failed: {mt5.last_error()}")
        return tick

    # ------------------------------------------------------------------
    # Account / positions
    # ------------------------------------------------------------------
    def account_info(self):
        info = mt5.account_info()
        if info is None:
            raise MT5Error(f"account_info() failed: {mt5.last_error()}")
        return info

    def open_positions(self):
        positions = mt5.positions_get(symbol=self.cfg.trading.symbol)
        if positions is None:
            return []
        return [p for p in positions if p.magic == self.cfg.trading.magic_number]

    # ------------------------------------------------------------------
    # Order execution
    # ------------------------------------------------------------------
    def send_market_order(
        self,
        side: str,
        volume: float,
        sl: Optional[float] = None,
        tp: Optional[float] = None,
        comment: str = "mt5-bot",
    ):
        """Send a market BUY or SELL order. ``side`` is 'buy' or 'sell'."""
        tick = self.tick()
        if side == "buy":
            order_type = mt5.ORDER_TYPE_BUY
            price = tick.ask
        elif side == "sell":
            order_type = mt5.ORDER_TYPE_SELL
            price = tick.bid
        else:
            raise ValueError(f"Invalid side: {side}")

        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": self.cfg.trading.symbol,
            "volume": float(volume),
            "type": order_type,
            "price": price,
            "deviation": self.cfg.trading.deviation,
            "magic": self.cfg.trading.magic_number,
            "comment": comment,
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_IOC,
        }
        if sl is not None:
            request["sl"] = float(sl)
        if tp is not None:
            request["tp"] = float(tp)

        result = mt5.order_send(request)
        if result is None:
            raise MT5Error(f"order_send returned None: {mt5.last_error()}")
        if result.retcode != mt5.TRADE_RETCODE_DONE:
            raise MT5Error(
                f"Order rejected: retcode={result.retcode} comment={result.comment}"
            )
        log.info(
            "Order filled | %s %.2f lots @ %.5f sl=%s tp=%s ticket=%s",
            side.upper(), volume, price, sl, tp, result.order,
        )
        return result

    def close_position(self, position):
        """Close an existing position with an opposite market order."""
        tick = self.tick()
        if position.type == mt5.POSITION_TYPE_BUY:
            order_type = mt5.ORDER_TYPE_SELL
            price = tick.bid
        else:
            order_type = mt5.ORDER_TYPE_BUY
            price = tick.ask

        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": position.symbol,
            "volume": position.volume,
            "type": order_type,
            "position": position.ticket,
            "price": price,
            "deviation": self.cfg.trading.deviation,
            "magic": self.cfg.trading.magic_number,
            "comment": "mt5-bot-close",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_IOC,
        }
        result = mt5.order_send(request)
        if result is None or result.retcode != mt5.TRADE_RETCODE_DONE:
            raise MT5Error(f"Failed to close position {position.ticket}: {mt5.last_error()}")
        log.info("Closed position %s", position.ticket)
        return result
