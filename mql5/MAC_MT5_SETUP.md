# Run LexiAutoTrader on a MacBook (MT5 app only, no rent)

You have a MacBook and use only the MetaTrader 5 app. Good news: the MT5 Mac
app can run the Expert Advisor. No Python, no VPS, no rent needed.

> Trade-off of free: the bot trades **only while your MacBook is awake and MT5
> is open**. If the Mac sleeps or shuts down, the bot stops until you open it
> again. (24/7 needs a VPS, which you don't want.)

---

## Step 1 — Install MetaTrader 5 for Mac

- Best: download the **macOS version from your broker's website** (search
  "<your broker> MetaTrader 5 Mac").
- If your broker has none, get the official one from MetaQuotes
  (metatrader5.com → Download → MacOS).
- Open the app and **log into your cent account** (same login/password/server).

> On Apple Silicon (M1/M2/M3) it runs through a built-in compatibility layer.
> If the broker's Mac build misbehaves, try the MetaQuotes one, then log into
> your broker's server inside it.

## Step 2 — Stop the Mac from sleeping (so the bot keeps running)

- **System Settings → Lock Screen / Battery → Displays/Computer sleep → Never**
  (at least while plugged in).
- Keep the MacBook **plugged in** and **MT5 open** while you want it trading.

## Step 3 — Add the bot using MetaEditor (easiest on Mac)

Putting files into the Mac MT5 folders is fiddly, so just paste the code:

1. In MT5, open **MetaEditor** (Tools → MetaQuotes Language Editor, or the
   MetaEditor icon in the toolbar).
2. **File → New → Expert Advisor (template) → Next**, name it
   **LexiAutoTrader**, finish. It creates a file with some starter code.
3. Open `mql5/LexiAutoTrader.mq5` from this repo (view it on GitHub on your
   Mac), **select all, copy**.
4. Back in MetaEditor, **select all** in the new file, **paste** to replace
   everything with the bot's code.
5. Click **Compile** (the Compile button, or ⌘+F7 / F7). You want
   **0 errors, 0 warnings**.

## Step 4 — Test on DEMO first (don't skip)

1. In MT5: **File → Open an Account → Demo** (fake money).
2. Open a **XAUUSD** chart, set timeframe **M5**.
3. In the **Navigator** panel → **Expert Advisors**, drag **LexiAutoTrader**
   onto the XAUUSD chart.
4. In the dialog, tick **Allow Algo Trading** → **OK**.
5. Click the **Algo Trading** button in the toolbar (turns green / enabled).
6. A 🙂 face in the chart's top-right corner = it's running. Watch the
   **Toolbox → Experts / Journal** tabs for messages.
7. Let it run on demo a few days and watch how it trades gold.

## Step 5 — Go live (only when ready)

1. Switch MT5 back to your **real cent account** (Navigator → right-click
   account → Login).
2. Open **XAUUSD M5**, drag the EA on again, **Allow Algo Trading → OK**,
   Algo Trading button enabled.
3. Keep the MacBook awake + plugged in + MT5 open.

## Step 6 — Watch from your phone too (optional)

- Install the MT5 app on your phone, log into the **same** account, and you'll
  see the trades the Mac is running. You can close any manually from the phone.

---

## Already configured for you

- **XAUUSD**, **M5** timeframe.
- **Minimum lot (0.01)**, **max 2 positions** (multiple entries along the trend).
- **Closes each trade once it's about +5 cents** (banks earnings fast).
- Safety: **ATR stop-loss** on each trade + stops for the day after **10% loss**.

Change any of these in the EA's inputs window when you drag it onto the chart.

> ⚠️ Gold is very volatile and ~$10 is tiny — the minimum lot can still lose a
> big share quickly, and the bot only protects you if the MacBook stays on with
> MT5 running. Demo first. Use only money you can afford to lose. Not financial
> advice.
