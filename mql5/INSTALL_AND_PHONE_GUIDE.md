# LexiAutoTrader — Install & Phone Guide

This is the **native MetaTrader 5 Expert Advisor** version of the bot. It runs
*inside* MT5 and trades fully on its own. You then watch it from the MT5 app on
your phone.

---

## ⚠️ Read this first — how "trading on your phone" actually works

**The MetaTrader 5 phone app cannot run a trading bot.** Bots (Expert Advisors)
only run on the **MT5 desktop terminal** or on a **VPS** (a cloud computer that
stays switched on). This is a hard limitation of MT5 itself — there is no app,
script, or trick that makes the phone app trade by itself.

What you *can* do — and what this guide sets up — is:

1. The bot runs on a computer/VPS that's always on.
2. You log into the **same account** in the MT5 app on your phone.
3. Trades the bot opens and closes appear on your phone automatically. You can
   watch profit/loss live and close anything manually if you want.

```
   Bot runs here (always on)                You watch here
   ┌──────────────────────────┐            ┌────────────────────┐
   │  MT5 desktop  OR  MT5 VPS │  ── same ─▶│  MT5 app on phone  │
   │  + LexiAutoTrader EA      │   account  │  (monitor / close) │
   └──────────────────────────┘            └────────────────────┘
```

---

## Step 1 — Install the EA (one-time, on a Windows PC)

1. Open **MetaTrader 5** (desktop). If you don't have a PC, see the VPS note
   below — you can do this on a rented Windows VPS instead.
2. Go to **Tools → MetaQuotes Language Editor** (or press **F4**).
3. In MetaEditor: **File → Open Data Folder** isn't needed — instead in MT5's
   **Navigator** panel, right-click **Expert Advisors → Open Folder**.
4. Copy `LexiAutoTrader.mq5` into that `MQL5\Experts` folder.
5. Back in MetaEditor, open `LexiAutoTrader.mq5` and click **Compile** (F7).
   You should see `0 errors, 0 warnings`.

## Step 2 — Test it on a DEMO account first

1. In MT5: **File → Open an Account** → pick a broker → choose **Demo**.
2. Open a chart for the symbol you want (e.g. **XAUUSD**) and set the timeframe
   (e.g. **M5**).
3. From **Navigator → Expert Advisors**, drag **LexiAutoTrader** onto the chart.
4. In the dialog, tick **Allow Algo Trading**, review the inputs, click **OK**.
5. Click the **Algo Trading** button in the top toolbar so it's green.
6. A smiley face 🙂 in the top-right of the chart means the EA is running. Watch
   the **Experts** and **Journal** tabs for its log messages.

> Let it run on demo for a while. Use the **Strategy Tester** (Ctrl+R) to
> backtest over history before risking anything.

## Step 3 — Run it 24/7 with MT5's built-in VPS (so your PC can be off)

1. In MT5, right-click your **account** in the Navigator → **Register a Virtual
   Server**.
2. Pick the plan/location, follow the prompts (small monthly fee).
3. Right-click the account again → **Migrate to virtual server** → choose to
   migrate **Experts and indicators**.
4. The EA now runs on MetaQuotes' server around the clock — your PC and phone
   can be off and it keeps trading.

## Step 4 — Watch it from your phone

1. Install **MetaTrader 5** from the App Store / Google Play.
2. Log in with the **same** login / password / server as the account the bot
   trades on.
3. Open the app whenever you like — the bot's trades are already there. The
   **Trade** tab shows open positions and live profit; **History** shows closed
   ones.

---

## Multiple entries + close-in-profit (what you asked for)

The EA is set up to **open multiple entries** and **close each one as soon as
it has earnings**:

- **Multiple entries (scale in)** — `InpPyramid = true`. After the first
  entry it keeps adding positions in the trend direction, spaced by
  `InpSpacingBars` bars, up to `InpMaxOpenPositions` (default 5).
- **Close in profit** — `InpCloseInProfit = true`. On every tick, any position
  whose floating profit is at least `InpMinProfitMoney` (default 0.50 in your
  account currency) is closed immediately. So winners get banked as they
  appear.
- **Basket option** — set `InpBasketProfitMoney` above 0 to instead close
  **all** positions at once when their combined profit reaches that amount.

As a **safety net** each position still carries an ATR stop-loss, plus optional
breakeven and trailing stop, so a losing entry can't run unbounded. Tune any of
these in the EA inputs when you attach it to the chart.

> ⚠️ Note: closing only winners while losers stay open (a "grid"/martingale-ish
> pattern) can show many small wins but leave large open losses in a strong
> adverse trend. The ATR stop-loss and the daily-loss limit exist to cap that —
> keep them on, and size small. Demo-test thoroughly first.

> ⚠️ **No bot can guarantee high earnings or any profit.** Bigger targets also
> mean some winners turn around before hitting them. Always demo-test first,
> risk only money you can afford to lose, and treat past results as no promise
> of future ones. This is not financial advice.

---

## Two versions in this repo

| Version | Folder | Best for |
|---|---|---|
| **MQL5 Expert Advisor** (this guide) | `mql5/` | Running on MT5 / MT5 VPS, watching from phone. **Recommended.** |
| **Python bot** | `src/`, `main.py` | Running on your own Windows PC/VPS, custom logic, backtesting. |

Both use the same EMA/RSI strategy and ATR-based risk management.
