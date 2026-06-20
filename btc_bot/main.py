"""Runner loop for paper / testnet / live.

    python -m btc_bot.main

In 'paper' mode fills are simulated by PaperBroker. In 'testnet'/'live'
mode market orders are sent via ccxt. LIVE mode is intentionally gated
behind an explicit confirmation env var because it risks real money.
"""
from __future__ import annotations

import os
import time
from datetime import datetime

from .config import SETTINGS
from .exchange import ExchangeClient, PaperBroker
from .indicators import ema
from .journal import Journal
from .risk import RiskManager
from .strategy import StrategyEngine


def _htf_trend_label(client: ExchangeClient, settings) -> str:
    df = client.fetch_ohlcv(settings.tf_htf, limit=250)
    e50, e200 = ema(df["close"], 50).iloc[-1], ema(df["close"], 200).iloc[-1]
    if e50 > e200:
        return "up"
    if e50 < e200:
        return "down"
    return "none"


def _guard_live(settings) -> None:
    if settings.is_live and os.getenv("I_UNDERSTAND_LIVE_RISK") != "yes":
        raise SystemExit(
            "LIVE mode blocked. Set I_UNDERSTAND_LIVE_RISK=yes only after you "
            "have tested on paper/testnet for weeks. Trading risks real money."
        )


def run(settings=SETTINGS, poll_seconds: int = 60) -> None:
    _guard_live(settings)
    client = ExchangeClient(settings)
    broker = PaperBroker(settings.start_equity)
    risk = RiskManager(settings, settings.start_equity)
    strat = StrategyEngine(settings, risk)
    journal = Journal()
    journal.log_event("start", f"mode={settings.mode} symbol={settings.symbol}")
    print(f"[{settings.mode}] running on {settings.symbol}. Ctrl-C to stop.")

    ctx = {"side": "long", "eq": broker.equity}      # persists across bars
    while True:
        try:
            df = client.fetch_ohlcv(settings.tf_entry, limit=300)
            trend = _htf_trend_label(client, settings)
            price = float(df["close"].iloc[-1])

            # optional spread sanity check for live data
            if settings.mode != "paper":
                try:
                    if client.spread_pct() > settings.max_spread_pct:
                        time.sleep(poll_seconds)
                        continue
                except Exception:       # noqa: BLE001
                    pass

            for a in strat.process(df, trend):
                _execute(a, strat, client, broker, settings, journal, ctx)

            risk.update_equity(broker.mark_to_market(price), datetime.utcnow())
            time.sleep(poll_seconds)
        except KeyboardInterrupt:
            print("stopped.")
            journal.log_event("stop")
            return
        except Exception as exc:        # noqa: BLE001
            journal.log_event("error", str(exc))
            print(f"error: {exc}; retrying in {poll_seconds}s")
            time.sleep(poll_seconds)


def _execute(a, strat, client, broker, settings, journal, state) -> None:
    def order(order_side: str, qty: float, price: float):
        if settings.mode == "paper":
            broker.fill(order_side, qty, price)
        else:
            client.market_order(order_side, qty)
            broker.fill(order_side, qty, price)   # keep local mirror

    if a.kind == "open":
        state["side"] = strat.idea.side
        state["eq"] = broker.equity
        order("buy" if state["side"] == "long" else "sell", a.qty, a.price)
        journal.log_event("open", a.info)
    elif a.kind == "add":
        order("buy" if state["side"] == "long" else "sell", a.qty, a.price)
        journal.log_event("add", a.info)
    elif a.kind == "reduce":
        order("sell" if state["side"] == "long" else "buy", a.qty, a.price)
        journal.log_event("reduce", a.info)
    elif a.kind == "close":
        qty = abs(broker.position_qty)
        if qty > 0:
            order("sell" if state["side"] == "long" else "buy", qty, a.price)
        pnl = broker.equity - state["eq"]
        lc = getattr(strat, "last_close", None)
        if lc:
            journal.record_trade(
                opened_at="", closed_at=datetime.utcnow().isoformat(),
                symbol=settings.symbol, side=lc["side"], confidence=lc["confidence"],
                entries=lc["entries"], avg_entry=lc["avg_entry"],
                exit_price=lc["exit"], qty=0.0, pnl=round(pnl, 4),
                r_multiple=round(lc["r_multiple"], 3), reason=lc["reason"],
            )
        journal.log_event("close", f"{a.info} pnl={pnl:.2f}")


if __name__ == "__main__":
    run()
