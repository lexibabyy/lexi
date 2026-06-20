"""Bar-by-bar backtester.

Fetches historical OHLCV via ccxt; if that fails (e.g. offline), it falls
back to a synthetic random-walk so the pipeline still runs end-to-end.

    python -m btc_bot.backtest
"""
from __future__ import annotations

from datetime import datetime, timedelta

import numpy as np
import pandas as pd

from .config import SETTINGS
from .exchange import ExchangeClient, PaperBroker
from .indicators import ema
from .journal import Journal
from .risk import RiskManager
from .strategy import StrategyEngine


def _synthetic(n: int = 4000, start: float = 60000.0, seed: int = 7) -> pd.DataFrame:
    rng = np.random.default_rng(seed)
    rets = rng.normal(0, 0.004, n).cumsum()
    close = start * np.exp(rets)
    high = close * (1 + np.abs(rng.normal(0, 0.0025, n)))
    low = close * (1 - np.abs(rng.normal(0, 0.0025, n)))
    openp = np.concatenate([[close[0]], close[:-1]])
    vol = np.abs(rng.normal(100, 40, n))
    idx = pd.date_range(datetime.utcnow() - timedelta(minutes=15 * n),
                        periods=n, freq="15min")
    return pd.DataFrame(
        {"open": openp, "high": high, "low": low, "close": close, "volume": vol},
        index=idx,
    )


def load_data(settings) -> pd.DataFrame:
    try:
        df = ExchangeClient(settings).fetch_ohlcv(settings.tf_entry, limit=1000)
        if len(df) > 300:
            return df
    except Exception as exc:            # noqa: BLE001 - offline fallback
        print(f"[backtest] live fetch failed ({exc}); using synthetic data")
    return _synthetic()


def htf_trend(df: pd.DataFrame, htf: str = "4h") -> pd.Series:
    res = df.resample(htf).agg({"close": "last"}).dropna()
    e50, e200 = ema(res["close"], 50), ema(res["close"], 200)
    trend = pd.Series("none", index=res.index)
    trend[e50 > e200] = "up"
    trend[e50 < e200] = "down"
    return trend.reindex(df.index, method="ffill").fillna("none")


def _fill_side(side: str, reduce: bool) -> str:
    """Order side to apply: opening long -> buy; reducing long -> sell."""
    if side == "long":
        return "sell" if reduce else "buy"
    return "buy" if reduce else "sell"


def run(settings=SETTINGS) -> dict:
    df = load_data(settings)
    trend = htf_trend(df, settings.tf_htf)
    broker = PaperBroker(settings.start_equity)
    risk = RiskManager(settings, settings.start_equity)
    strat = StrategyEngine(settings, risk)
    journal = Journal(":memory:")

    warmup = window = 250
    side = "long"
    equity_at_open = broker.equity

    for i in range(warmup, len(df)):
        sub = df.iloc[: i + 1].tail(window)
        price = float(df["close"].iloc[i])
        now = df.index[i].to_pydatetime()

        for a in strat.process(sub, trend.iloc[i]):
            if a.kind == "open":
                side = strat.idea.side
                equity_at_open = broker.equity
                broker.fill(_fill_side(side, reduce=False), a.qty, a.price)
            elif a.kind == "add":
                broker.fill(_fill_side(side, reduce=False), a.qty, a.price)
            elif a.kind == "reduce":
                broker.fill(_fill_side(side, reduce=True), a.qty, a.price)
            elif a.kind == "close":
                qty = abs(broker.position_qty)
                if qty > 0:
                    broker.fill(_fill_side(side, reduce=True), qty, a.price)
                pnl = broker.equity - equity_at_open
                risk.note_idea_result(pnl)
                lc = getattr(strat, "last_close", None)
                if lc:
                    journal.record_trade(
                        opened_at="", closed_at=now.isoformat(),
                        symbol=settings.symbol, side=lc["side"],
                        confidence=lc["confidence"], entries=lc["entries"],
                        avg_entry=lc["avg_entry"], exit_price=lc["exit"],
                        qty=0.0, pnl=round(pnl, 4),
                        r_multiple=round(lc["r_multiple"], 3), reason=lc["reason"],
                    )
            # 'move_stop' needs no broker action
        risk.update_equity(broker.mark_to_market(price), now)

    stats = journal.stats()
    final = round(broker.mark_to_market(float(df["close"].iloc[-1])), 2)
    stats["final_equity"] = final
    stats["start_equity"] = settings.start_equity
    stats["return_pct"] = round(100 * (final / settings.start_equity - 1), 2)
    print("=== Backtest result ===")
    for k, v in stats.items():
        print(f"  {k:14}: {v}")
    return stats


if __name__ == "__main__":
    run()
