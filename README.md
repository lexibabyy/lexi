# MetaTrader 5 Automated Trading Bot

An automated trading bot for [MetaTrader 5](https://www.metatrader5.com/).
It connects to your MT5 terminal, evaluates the market on every new candle
using a configurable strategy, sizes positions from a risk budget, and
places/manages trades automatically — including stop-loss, take-profit, a
daily loss limit, and a safe **dry-run** mode.

> ⚠️ **Risk warning.** Trading leveraged instruments carries a high risk of
> losing money. This software is provided for educational purposes with **no
> guarantee of profit**. Always run on a **demo account** first, keep
> `dry_run: true` until you fully understand the behaviour, and never risk
> money you cannot afford to lose. You are solely responsible for any trades
> placed.

## 📱 Run it from your phone

The MT5 **phone app itself can't run a bot** — automated trading has to run on
an always-on machine (a cheap Windows **VPS** is the usual choice). There are
two ways to get the "it's on my phone" experience:

### Option A — Control everything from Telegram (recommended)

[`telegram_bot.py`](telegram_bot.py) turns your phone into the bot's remote
control. Install the engine once on a VPS, then from the **Telegram app** you:

```
/run        start auto-trading
/stop       stop auto-trading
/status     balance, equity, bot state
/positions  open positions + live P/L
/closeall   close everything now
```

…and you get a 🔔 push alert on every trade it opens or closes. Only your own
chat id can control it. See **[Phone / Telegram setup](#-phone--telegram-setup)**
below.

### Option B — Native Expert Advisor + MT5 mobile

[`mql5/LexiAutoTrader.mq5`](mql5/LexiAutoTrader.mq5) runs inside MT5 / MT5's
built-in VPS. Log into the **same account** in the MT5 phone app and watch
trades appear automatically. Full walkthrough:
[`mql5/INSTALL_AND_PHONE_GUIDE.md`](mql5/INSTALL_AND_PHONE_GUIDE.md).

> **Default setup: XAUUSD (gold), multiple entries, close-in-profit.** The bot
> scales into the trend with several positions and closes each one as soon as
> it shows a profit, with an ATR stop-loss + daily-loss limit as the safety
> net. All tunable in `config.yaml` / the EA inputs.

## Features

- 🔌 **Direct MT5 integration** via the official `MetaTrader5` Python package.
- 📈 **Built-in strategy**: EMA crossover filtered by RSI (easy to extend).
- 🛡️ **Risk management**: percent-of-equity position sizing, ATR-based
  stop-loss/take-profit, per-trade lot caps, and a daily loss limit.
- 🤖 **Fully automated loop**: evaluates each closed candle and trades on its own.
- 🧪 **Dry-run mode**: logs the trades it *would* make without sending orders.
- 🔁 **Backtester**: validate the strategy on historical data offline.
- ✅ **Unit tested** indicators, strategy, and risk logic (no MT5 needed to test).

## How it works

```
 MT5 terminal ──► MT5Client ──► Strategy (EMA/RSI) ──► Signal
                                     │
                                     ▼
                          Risk (lot size, SL/TP, daily guard)
                                     │
                                     ▼
                        TradingBot loop ──► order_send (live)
                                          └► log only  (dry-run)
```

The bot acts only on the **last fully-closed candle**, so it evaluates each
bar exactly once and avoids acting on a repainting, still-forming candle.

## Requirements

- **Windows** with the MetaTrader 5 desktop terminal installed and logged in
  (the `MetaTrader5` Python package only runs on Windows).
- **Python 3.9+**.
- A broker account (start with a **demo** account).

> The strategy/risk/backtest code is cross-platform and unit-testable on any
> OS; only the live connection requires Windows + the terminal.

## Setup

```bash
pip install -r requirements.txt
```

Edit `config.yaml` to set your symbol, timeframe and risk. To attach to an
already-running, logged-in terminal, leave the `account` credentials blank.
To log in programmatically, either fill them in or use environment variables
(recommended for secrets):

```bash
export MT5_LOGIN=12345678
export MT5_PASSWORD="your-password"
export MT5_SERVER="MetaQuotes-Demo"
```

## Usage

**1. Always start in dry-run** (this is the default in `config.yaml`):

```bash
python main.py
```

Watch `bot.log` / the console to confirm the signals and sizing look sane.

**2. Backtest the strategy** on historical data:

```bash
python backtest.py --from-mt5 --bars 5000     # pull history from MT5
python backtest.py --csv my_data.csv          # or use a CSV
```

**3. Go live** only once you're confident, on a demo account first:

```bash
python main.py --live
```

`--live` overrides `dry_run` and **sends real orders**.

## 📲 Phone / Telegram setup

1. **Create your bot:** in Telegram, message **@BotFather** → `/newbot` → copy
   the **token** it gives you.
2. **Find your chat id:** message your new bot anything, then open
   `https://api.telegram.org/bot<TOKEN>/getUpdates` in a browser and read the
   `"chat":{"id":...}` value.
3. **Configure** either via env vars (recommended) or `config.yaml`:
   ```bash
   export TELEGRAM_TOKEN="123456:ABC..."
   export TELEGRAM_CHAT_ID="987654321"
   ```
4. **Run it on your always-on PC/VPS:**
   ```bash
   python telegram_bot.py            # dry-run (safe default)
   python telegram_bot.py --live     # real orders
   ```
5. From your phone, send `/help`, then `/run` to start trading and `/stop`
   whenever you want. With `start_paused: true` (default) the bot waits for your
   `/run` so you're always in control.

> The VPS keeps trading even when your phone is off; you just open Telegram to
> check in or take over. Only the configured `chat_id` can issue commands.

## Configuration reference

See `config.yaml` for the full annotated list. Key settings:

| Section | Key | Meaning |
|---|---|---|
| `trading` | `symbol`, `timeframe` | What and on which timeframe to trade |
| `trading` | `poll_interval_seconds` | How often the bot checks the market |
| `trading` | `max_open_positions` | Cap on simultaneous bot positions |
| `entries` | `pyramid` / `spacing_bars` | Add multiple entries along the trend, spaced out |
| `exit` | `close_in_profit` / `min_profit_money` | Close each position once it's in profit |
| `exit` | `basket_profit_money` | Close ALL positions when combined profit hits target |
| `risk` | `risk_per_trade_pct` | % of equity risked per trade |
| `risk` | `stop_loss_atr_mult` / `take_profit_atr_mult` | SL/TP as ATR multiples |
| `risk` | `max_daily_loss_pct` | Stop trading after this daily drawdown |
| `strategy` | `fast_ema`, `slow_ema`, `rsi_*` | Strategy parameters |
| `runtime` | `dry_run` | `true` = simulate, `false` = live |

## Writing your own strategy

Subclass `Strategy` in `src/strategy.py`, implement `generate(df) -> Signal`,
and register it in `build_strategy`. A `Signal` carries a `type`
(`BUY`/`SELL`/`HOLD`) and the current `atr` used for SL/TP sizing.

## Running the tests

```bash
pip install pytest
pytest
```

The tests cover indicators, the strategy, and risk sizing — none of them
require MetaTrader 5 to be installed.

## Project layout

```
.
├── main.py             # entry point / CLI
├── backtest.py         # offline backtester
├── config.yaml         # configuration
├── requirements.txt
└── src/
    ├── config.py       # config loading & validation
    ├── mt5_client.py   # MT5 connection + order execution
    ├── indicators.py   # EMA, RSI, ATR
    ├── strategy.py     # signal generation
    ├── risk.py         # position sizing & daily loss guard
    ├── exits.py        # close-in-profit / basket exit logic
    ├── bot.py          # the automated trading loop
    ├── notifier.py     # phone push alerts (Telegram)
    └── controller.py   # start/stop the loop in a background thread
mql5/
    ├── LexiAutoTrader.mq5            # native MT5 Expert Advisor
    └── INSTALL_AND_PHONE_GUIDE.md    # EA install + phone walkthrough
telegram_bot.py         # control the bot from your phone via Telegram
```

## Disclaimer

This is not financial advice. Use at your own risk.
