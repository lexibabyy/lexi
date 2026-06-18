# Trade XAUUSD on your phone for FREE (no VPS, no rent)

You don't want to rent anything and you only have a phone. A fully-automatic
bot is impossible that way (MT5's own limitation). But you can trade the
**exact same strategy by hand** in the free MT5 phone app. You become the bot.

This costs nothing. It just needs you to check the chart now and then.

---

## One-time setup in the MT5 phone app

1. Install **MetaTrader 5** (App Store / Play Store) and log into your account.
2. Open the **XAUUSD** chart. Set the timeframe to **M5** (tap the timeframe
   button at the top).
3. Add three indicators (tap the **f(x)** / indicators icon → **Main window** /
   **Indicators window**):
   - **Moving Average**, Period **12**, Method **Exponential**, Apply to Close.
   - **Moving Average**, Period **26**, Method **Exponential**, Apply to Close.
   - **RSI (Relative Strength Index)**, Period **14**.

Now you have a fast line (EMA 12), a slow line (EMA 26), and RSI underneath —
the same things the bot looks at.

---

## The rules (do exactly this)

### When to BUY (go long)
- The **EMA 12 crosses ABOVE the EMA 26** (fast line moves above slow line), **and**
- **RSI is below 70**.

### When to SELL (go short)
- The **EMA 12 crosses BELOW the EMA 26** (fast line moves below slow line), **and**
- **RSI is above 30**.

### How big
- Volume **0.01** (the minimum). Nothing bigger on a ~$10 account.
- Keep **at most 2 trades** open at once.

### Stop loss (protect yourself — always set it)
- When you open the trade, set a **Stop Loss** about **$3–4 away** from your
  entry price (gold moves fast). On the order screen, type it in the **S/L** box.
- This is your safety net so one bad move can't wipe the account.

### When to CLOSE (take profit — what you asked for)
- Close the trade **as soon as it shows a small profit** (e.g. **+5 cents** or
  more). Tap the position → **Close**.
- Bank the small wins; don't get greedy waiting for big ones on this size.

### Stop for the day
- If you've **lost about 10%** of your balance in a day, **stop trading** until
  tomorrow. Don't chase it back.

---

## How to place an order on the phone

1. Tap **Trade** (bottom) → tap the **+** or the symbol → **XAUUSD**.
2. Choose **Buy** or **Sell** by Market, set **Volume 0.01**, fill the **S/L**.
3. Confirm. The trade appears in the **Trade** tab with live profit/loss.
4. To close: tap the open position → **Close with profit**.

---

## Honest notes

- This is **manual** — it only works when you actually look at the chart. The
  M5 timeframe means a possible signal every few minutes; checking a few times
  a day is realistic, you won't catch them all, and that's okay.
- Gold is **very volatile** and $10 is tiny. The minimum lot can still lose a
  big chunk fast. **Always set the stop loss.** Use only money you can lose.
- If you later decide you want it fully automatic, you'll need either a free
  **broker VPS** (ask your broker's support) or a PC/VPS — see
  `PHONE_ONLY_SETUP.md`. This is not financial advice.
