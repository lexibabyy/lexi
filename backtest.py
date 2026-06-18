#!/usr/bin/env python3
"""Offline backtester for the EMA/RSI strategy.

Lets you sanity-check the strategy on historical candles WITHOUT a live
MT5 connection. It can pull history from a running terminal, or run on a
CSV with time/open/high/low/close columns.

Usage:
    python backtest.py --from-mt5            # requires MT5 installed
    python backtest.py --csv data.csv
"""
from __future__ import annotations

import argparse
import logging

import pandas as pd

from src.config import Config
from src.strategy import SignalType, build_strategy

log = logging.getLogger("backtest")


def load_csv(path: str) -> pd.DataFrame:
    df = pd.read_csv(path)
    df["time"] = pd.to_datetime(df["time"])
    return df


def load_from_mt5(cfg: Config, bars: int) -> pd.DataFrame:
    from src.mt5_client import MT5Client

    client = MT5Client(cfg)
    client.connect()
    try:
        return client.get_rates(bars)
    finally:
        client.shutdown()


def run_backtest(cfg: Config, df: pd.DataFrame) -> None:
    strategy = build_strategy(cfg.strategy, cfg.risk.atr_period)

    position = None  # ('buy'/'sell', entry_price, sl, tp)
    trades = []
    equity = 10_000.0
    risk = cfg.risk

    warmup = max(cfg.strategy.slow_ema, cfg.strategy.rsi_period, risk.atr_period) + 2

    for end in range(warmup, len(df)):
        window = df.iloc[: end + 1]
        bar = window.iloc[-1]
        price = bar["close"]

        # Manage an open position against the current bar high/low.
        if position:
            side, entry, sl, tp = position
            hit_sl = bar["low"] <= sl if side == "buy" else bar["high"] >= sl
            hit_tp = bar["high"] >= tp if side == "buy" else bar["low"] <= tp
            if hit_sl or hit_tp:
                exit_price = sl if hit_sl else tp
                pnl = (exit_price - entry) if side == "buy" else (entry - exit_price)
                trades.append(pnl)
                equity += pnl * 10_000  # nominal scaling for reporting
                position = None

        if position:
            continue

        signal = strategy.generate(window)
        if signal.type == SignalType.HOLD or not signal.atr:
            continue

        sl_dist = signal.atr * risk.stop_loss_atr_mult
        tp_dist = signal.atr * risk.take_profit_atr_mult
        if signal.type == SignalType.BUY:
            position = ("buy", price, price - sl_dist, price + tp_dist)
        else:
            position = ("sell", price, price + sl_dist, price - tp_dist)

    wins = [t for t in trades if t > 0]
    losses = [t for t in trades if t <= 0]
    n = len(trades)
    print("=" * 48)
    print(f"Trades:    {n}")
    if n:
        print(f"Win rate:  {len(wins) / n * 100:.1f}%")
        print(f"Avg win:   {sum(wins) / len(wins):.5f}" if wins else "Avg win:   n/a")
        print(f"Avg loss:  {sum(losses) / len(losses):.5f}" if losses else "Avg loss:  n/a")
        gross_win = sum(wins)
        gross_loss = abs(sum(losses)) or 1e-9
        print(f"Profit factor: {gross_win / gross_loss:.2f}")
    print("=" * 48)


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    p = argparse.ArgumentParser(description="Backtest the EMA/RSI strategy")
    p.add_argument("-c", "--config", default="config.yaml")
    p.add_argument("--csv", help="CSV file with time/open/high/low/close")
    p.add_argument("--from-mt5", action="store_true", help="pull history from MT5")
    p.add_argument("--bars", type=int, default=5000)
    args = p.parse_args()

    cfg = Config.load(args.config)
    if args.csv:
        df = load_csv(args.csv)
    elif args.from_mt5:
        df = load_from_mt5(cfg, args.bars)
    else:
        p.error("provide --csv PATH or --from-mt5")
        return 2

    run_backtest(cfg, df)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
