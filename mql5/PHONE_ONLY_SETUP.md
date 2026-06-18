# Run the bot with ONLY a phone (XAUUSD)

You don't own a PC — that's fine. You'll rent a small **Windows VPS** (a
computer in the cloud) and control its screen from your phone. MetaTrader 5 and
the bot run on that VPS 24/7; you watch from the MT5 app on your phone.

> A bot can NOT run inside the MT5 phone app — this is the only way to do it
> phone-only. There is no app or trick that avoids the always-on computer.

---

## ⚠️ Money reality check first

A Windows VPS costs about **$5–15/month**. Your account is ~**$10** (1000 cents).
So the VPS can cost more than the account. Do this only to **learn**, or fund a
bit more, or check if your broker offers a **free MT5 VPS** (many do if you keep
a minimum balance/volume — ask their support). Don't spend rent money on this.

---

## Step 1 — Rent a Windows VPS

- Search for a **"Windows VPS"** or **"Forex VPS"** provider and pick the
  cheapest Windows plan (1 GB RAM is enough for one MT5).
- After paying you'll get three things: an **IP address**, a **username**
  (usually `Administrator`), and a **password**. Keep them.

## Step 2 — Connect to the VPS from your phone

1. Install **Microsoft Remote Desktop** (also called **RD Client**) from the
   App Store / Play Store — it's free.
2. Open it → add a PC → enter the **IP address** → enter the **username** and
   **password** from Step 1 → connect.
3. You're now looking at a Windows desktop *on your phone*. You operate it by
   tapping. (You can disconnect anytime — the VPS keeps running.)

## Step 3 — Install MetaTrader 5 on the VPS

1. On the VPS, open the web browser (Edge).
2. Go to your **broker's website**, download their **MetaTrader 5**, install it.
3. Log in with your **cent account** (the same login/password/server you use on
   your phone — the one with the 1000 balance).

## Step 4 — Put the bot on the VPS

1. On the VPS browser, open your GitHub repo and the file
   `mql5/LexiAutoTrader.mq5` → click **Raw** → **save** the file.
2. In MT5, press **F4** to open MetaEditor.
3. In MT5's **Navigator** (left panel), right-click **Expert Advisors** →
   **Open Folder**. Move the saved `LexiAutoTrader.mq5` into that folder
   (the `MQL5\Experts` folder).
4. Back in MetaEditor, open `LexiAutoTrader.mq5` → click **Compile** (F7).
   You want **0 errors**.

## Step 5 — Test on DEMO (do not skip)

1. In MT5: **File → Open an Account → Demo** (any broker, fake money).
2. Open a **XAUUSD** chart, set timeframe to **M5**.
3. From **Navigator → Expert Advisors**, drag **LexiAutoTrader** onto the
   XAUUSD chart → tick **Allow Algo Trading** → **OK**.
4. Click the **Algo Trading** button in the top toolbar (it turns green).
5. A 🙂 in the chart's top-right corner means it's running. Watch the
   **Experts** and **Journal** tabs at the bottom for its messages.
6. Let it run on demo for **a few days** and watch how it trades gold before
   risking real money.

## Step 6 — Go live (only when you're ready)

1. In MT5, switch back to your **real cent account** (right-click it in
   Navigator → Login).
2. Open the **XAUUSD M5** chart on the real account and drag the EA on again,
   **Allow Algo Trading → OK**, Algo Trading button green.
3. Leave the VPS running. You can close Remote Desktop on your phone — the VPS
   and the bot keep going.

## Step 7 — Watch from your phone

- Open the **MetaTrader 5 app**, log into the **same** real account.
- The **Trade** tab shows open positions and live profit; **History** shows
  closed ones. You can also close anything manually here whenever you want.

---

## What it's set to do (already configured for you)

- **Symbol:** XAUUSD (gold), **M5** timeframe.
- **Smallest lot** (0.01) — the minimum your broker allows.
- **Up to 2 positions** at once (multiple entries along the trend).
- **Closes each trade as soon as it's +5 cents** (banks earnings quickly).
- **Safety net:** an ATR stop-loss on every trade + stops trading for the day
  after a 10% loss.

You can change any of these in the EA's inputs when you drag it on the chart.

> ⚠️ Gold is very volatile and your balance is tiny. The minimum lot can still
> lose a big share of $10 fast, and "close winners, hold losers" can leave a
> large open loss in a strong adverse move. Treat the $10 as money you can fully
> afford to lose. No bot guarantees profit. This is not financial advice.
