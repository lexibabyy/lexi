# SMC Bitcoin Bot (Phase 1 foundation)

A modular, structure-based BTC trading framework. **This is NOT a grid or
martingale bot.** It only enters after market-structure confirmation and
only scales into *winning* trades — never adds to losers.

> ⚠️ **Read this first.** No trading bot is guaranteed to be profitable.
> The Smart Money Concept detectors here (BOS / CHoCH / liquidity sweep /
> FVG) are *heuristic approximations* of subjective ideas. This code ships
> in **PAPER mode by default**. Validate on paper / exchange testnet for
> weeks before risking real money, and never trade money you can't lose.

## What is implemented (Phase 1)
- `config.py` — settings + env-based API keys, PAPER/TESTNET/LIVE modes
- `indicators.py` — EMA, RSI, ATR, RSI-divergence, volume confirmation
- `structure.py` — swing detection, HH/HL/LH/LL, BOS, CHoCH, sweep, FVG
- `confidence.py` — the 0–100 confidence engine (5 × 20 points)
- `risk.py` — 0.5%/entry, 2% cycle, 3% daily, 8% weekly, 10% emergency,
  3-consecutive-loss pause
- `strategy.py` — setup detection + the 4-step *scale-into-winners* logic,
  TP ladder (1R/2R/3R/trail) and move-to-breakeven
- `exchange.py` — ccxt adapter (Binance / Bybit, testnet) + a PaperBroker
- `journal.py` — SQLite trade journal
- `backtest.py` — bar-by-bar backtester over historical OHLCV
- `main.py` — paper/live runner loop

## Not yet done (Phase 2+, honest list)
- Web dashboard (only a CLI summary is included)
- News/economic-calendar filter (stub — wire your own feed)
- Robust live-trading hardening (reconnects, partial-fill handling,
  exchange-specific quirks, order reconciliation) — needs real testing
- Walk-forward optimisation

## Setup
```bash
cd btc_bot
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Keys (only needed for testnet/live; never commit these):
export EXCHANGE=binance          # or bybit
export TRADING_MODE=paper        # paper | testnet | live
export API_KEY=...               # trade-only, NO withdrawal, IP-whitelisted
export API_SECRET=...
```

## Run
```bash
python -m btc_bot.backtest        # backtest on historical data
python -m btc_bot.main            # paper/live loop
```

Not financial advice. Trading is high-risk.
