#!/usr/bin/env python3
"""Control the MetaTrader 5 trading bot entirely from your phone via Telegram.

Run this on the always-on machine/VPS where MT5 is installed. Then, from the
Telegram app on your phone, message your bot:

    /run        start auto-trading
    /stop       stop auto-trading (leaves open trades alone)
    /status     account balance/equity + bot state
    /positions  list open positions and live P/L
    /closeall   close every open position now
    /help       show commands

Only the chat id in your config (telegram.chat_id) is allowed to control it.

Setup (one time):
    1. In Telegram, message @BotFather -> /newbot -> copy the token.
    2. Message your new bot once, then visit
       https://api.telegram.org/bot<TOKEN>/getUpdates to find your chat id.
    3. Put token + chat_id in config.yaml (telegram:) or set
       TELEGRAM_TOKEN / TELEGRAM_CHAT_ID env vars.

Usage:
    python telegram_bot.py            # dry-run by default (safe)
    python telegram_bot.py --live     # send real orders
"""
from __future__ import annotations

import argparse
import logging
import sys
import time

import requests

from src.config import Config
from src.controller import BotController
from src.mt5_client import MT5Client, MT5Error
from src.notifier import TelegramNotifier

log = logging.getLogger("telegram_bot")

HELP_TEXT = (
    "🤖 <b>MT5 Trading Bot</b>\n\n"
    "/run – start auto-trading\n"
    "/stop – stop auto-trading\n"
    "/status – balance, equity, state\n"
    "/positions – open positions &amp; P/L\n"
    "/closeall – close all positions now\n"
    "/help – this message"
)


class TelegramController:
    def __init__(self, config: Config, controller: BotController):
        self.cfg = config
        self.controller = controller
        self.token = config.telegram.token
        self.chat_id = str(config.telegram.chat_id)
        self._api = f"https://api.telegram.org/bot{self.token}"
        self._offset = None

    def _send(self, text: str) -> None:
        try:
            requests.post(
                f"{self._api}/sendMessage",
                json={"chat_id": self.chat_id, "text": text, "parse_mode": "HTML"},
                timeout=10,
            )
        except requests.RequestException as exc:
            log.warning("Failed to send Telegram reply: %s", exc)

    def _handle(self, text: str) -> str:
        cmd = text.strip().split()[0].lower().lstrip("/")
        # Strip any @botname suffix Telegram adds in groups.
        cmd = cmd.split("@")[0]
        try:
            if cmd in ("start", "help"):
                return HELP_TEXT
            if cmd == "run":
                return self.controller.start()
            if cmd == "stop":
                return self.controller.stop()
            if cmd == "status":
                return self.controller.status_text()
            if cmd == "positions":
                return self.controller.positions_text()
            if cmd == "closeall":
                return self.controller.close_all()
            return "Unknown command. Send /help."
        except MT5Error as exc:
            return f"⚠️ MT5 error: {exc}"
        except Exception as exc:  # never crash the listener
            log.exception("Command handler error")
            return f"⚠️ Error: {exc}"

    def poll_forever(self) -> None:
        self._send("✅ Trading bot online. Send /help for commands.")
        log.info("Listening for Telegram commands...")
        while True:
            try:
                params = {"timeout": 30}
                if self._offset is not None:
                    params["offset"] = self._offset
                resp = requests.get(f"{self._api}/getUpdates", params=params, timeout=40)
                data = resp.json()
                for update in data.get("result", []):
                    self._offset = update["update_id"] + 1
                    msg = update.get("message") or update.get("channel_post")
                    if not msg:
                        continue
                    chat_id = str(msg.get("chat", {}).get("id"))
                    text = msg.get("text", "")
                    if not text:
                        continue
                    if chat_id != self.chat_id:
                        log.warning("Ignoring command from unauthorized chat %s", chat_id)
                        continue
                    reply = self._handle(text)
                    self._send(reply)
            except requests.RequestException as exc:
                log.warning("Telegram poll error: %s; retrying in 5s", exc)
                time.sleep(5)
            except KeyboardInterrupt:
                log.info("Shutting down listener.")
                break


def setup_logging(level: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(asctime)s | %(levelname)-7s | %(name)s | %(message)s",
        handlers=[logging.StreamHandler(sys.stdout)],
    )


def main() -> int:
    p = argparse.ArgumentParser(description="Telegram control for the MT5 bot")
    p.add_argument("-c", "--config", default="config.yaml")
    p.add_argument("--live", action="store_true", help="send real orders")
    args = p.parse_args()

    config = Config.load(args.config)
    if args.live:
        config.runtime.dry_run = False
    setup_logging(config.runtime.log_level)

    if not config.telegram.token or not config.telegram.chat_id:
        log.error("Telegram token/chat_id not set. Configure telegram: in "
                  "config.yaml or TELEGRAM_TOKEN / TELEGRAM_CHAT_ID env vars.")
        return 1

    notifier = TelegramNotifier(config.telegram.token, config.telegram.chat_id)

    try:
        client = MT5Client(config)
        client.connect()
    except MT5Error as exc:
        log.error("Could not connect to MetaTrader 5: %s", exc)
        notifier.send(f"⚠️ Could not connect to MT5: {exc}")
        return 1

    controller = BotController(config, client, notifier=notifier)

    if not config.telegram.start_paused:
        controller.start()

    tg = TelegramController(config, controller)
    try:
        tg.poll_forever()
    finally:
        controller.stop()
        client.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
