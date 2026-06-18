from src.notifier import Notifier, TelegramNotifier


def test_base_notifier_is_noop():
    # Should not raise and should do nothing.
    Notifier().send("hello")


def test_telegram_notifier_builds_url():
    n = TelegramNotifier(token="abc123", chat_id=42)
    assert n.chat_id == "42"
    assert n._url == "https://api.telegram.org/botabc123/sendMessage"


def test_telegram_notifier_swallows_network_errors(monkeypatch):
    import src.notifier as mod

    def boom(*args, **kwargs):
        raise mod.requests.RequestException("network down")

    monkeypatch.setattr(mod.requests, "post", boom)
    # Must not raise even when the network call fails.
    TelegramNotifier(token="t", chat_id="1").send("hi")
