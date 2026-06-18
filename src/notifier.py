"""Push notifications for the bot (so alerts reach your phone).

The default ``Notifier`` is a no-op. ``TelegramNotifier`` sends messages to
a Telegram chat via the Bot API over plain HTTP, so it works from any thread
without extra async dependencies.
"""
from __future__ import annotations

import logging

import requests

log = logging.getLogger(__name__)


class Notifier:
    """No-op notifier. Override ``send`` to deliver messages somewhere."""

    def send(self, text: str) -> None:  # pragma: no cover - trivial
        pass


class TelegramNotifier(Notifier):
    def __init__(self, token: str, chat_id: str, timeout: int = 10):
        self.token = token
        self.chat_id = str(chat_id)
        self.timeout = timeout
        self._url = f"https://api.telegram.org/bot{token}/sendMessage"

    def send(self, text: str) -> None:
        try:
            resp = requests.post(
                self._url,
                json={"chat_id": self.chat_id, "text": text, "parse_mode": "HTML"},
                timeout=self.timeout,
            )
            if resp.status_code != 200:
                log.warning("Telegram sendMessage failed: %s %s",
                            resp.status_code, resp.text)
        except requests.RequestException as exc:
            log.warning("Telegram notification error: %s", exc)
