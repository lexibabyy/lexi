#!/usr/bin/env python3
"""Entry point for the MetaTrader 5 automated trading bot.

Usage:
    python main.py                 # uses config.yaml
    python main.py -c my.yaml      # custom config
    python main.py --live          # force live trading (overrides dry_run)
"""
from __future__ import annotations

import argparse
import logging
import sys

from src.bot import TradingBot
from src.config import Config
from src.mt5_client import MT5Client, MT5Error


def setup_logging(level: str, log_file: str) -> None:
    handlers = [logging.StreamHandler(sys.stdout)]
    if log_file:
        handlers.append(logging.FileHandler(log_file))
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(asctime)s | %(levelname)-7s | %(name)s | %(message)s",
        handlers=handlers,
    )


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="MetaTrader 5 automated trading bot")
    p.add_argument("-c", "--config", default="config.yaml", help="path to config file")
    p.add_argument("--live", action="store_true",
                   help="force LIVE trading (sends real orders, overrides dry_run)")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    config = Config.load(args.config)

    if args.live:
        config.runtime.dry_run = False

    setup_logging(config.runtime.log_level, config.runtime.log_file)
    log = logging.getLogger("main")

    if not config.runtime.dry_run:
        log.warning("LIVE TRADING ENABLED — real orders will be placed!")

    try:
        client = MT5Client(config)
        client.connect()
    except MT5Error as exc:
        log.error("Could not connect to MetaTrader 5: %s", exc)
        return 1

    bot = TradingBot(config, client)
    try:
        bot.run()
    finally:
        client.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
