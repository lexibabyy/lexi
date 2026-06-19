//+------------------------------------------------------------------+
//|                                              LexiAutoTrader.mq5   |
//|   Automated MetaTrader 5 Expert Advisor                          |
//|                                                                  |
//|   Designed for XAUUSD (gold) — attach it to a XAUUSD chart.      |
//|                                                                  |
//|   Entries : EMA crossover filtered by RSI, then keeps adding     |
//|             entries along the trend (scale in / multiple         |
//|             positions), spaced out by bars, up to a max.         |
//|   Exits   : closes EACH position as soon as it shows profit      |
//|             (close-in-profit). An ATR stop-loss, breakeven and   |
//|             trailing stop act as a safety net per position.      |
//|                                                                  |
//|   HOW TO USE (so it trades by itself while you watch on phone):  |
//|     1. Open MetaEditor in MT5 desktop, paste this file, Compile. |
//|     2. In MT5, drag "LexiAutoTrader" from Navigator onto a chart.|
//|     3. Enable "Algo Trading" (the button in the toolbar).        |
//|     4. (Optional) Right-click the account -> Register a Virtual  |
//|        Server (MT5 VPS) so it runs 24/7 with your PC off.        |
//|     5. Log into the SAME account in the MT5 app on your phone to |
//|        watch trades open/close automatically.                    |
//|                                                                  |
//|   RISK WARNING: Trading is high-risk. No profit is guaranteed.   |
//|   Test on a DEMO account first. Not financial advice.            |
//+------------------------------------------------------------------+
#property copyright "Lexi"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//--- Inputs: Strategy -----------------------------------------------
input int      InpFastEMA            = 12;        // Fast EMA period
input int      InpSlowEMA            = 26;        // Slow EMA period
input int      InpRSIPeriod          = 14;        // RSI period
input double   InpRSIOverbought      = 70.0;      // RSI overbought (block buys above)
input double   InpRSIOversold        = 30.0;      // RSI oversold (block sells below)

//--- Inputs: Entry-quality filters (avoid choppy, sideways markets) --
input bool     InpUseADX             = true;      // Only enter when a real trend exists
input int      InpADXPeriod          = 14;        // ADX period
input double   InpADXMin             = 18.0;      // Min ADX to allow an entry (higher=stricter)
input bool     InpUseHTFTrend        = true;      // Only trade WITH the higher-timeframe trend
input ENUM_TIMEFRAMES InpTrendTF      = PERIOD_H1; // Higher timeframe to define the trend

//--- Inputs: Risk & exits -------------------------------------------
input double   InpRiskPerTradePct    = 1.0;       // Risk per trade (% of equity)
input int      InpATRPeriod          = 14;        // ATR period
input double   InpSLAtrMult          = 1.5;       // Stop-loss = ATR x this
input double   InpTPAtrMult          = 4.0;       // Take-profit = ATR x this (wide = let it run)
input double   InpMinLot             = 0.10;      // Minimum lot (grid trade size)
input double   InpMaxLot             = 0.10;      // Maximum lot (grid trade size)
input double   InpMaxDailyLossPct    = 10.0;      // Stop trading after this daily loss (%)

//--- Inputs: "Let winners run" --------------------------------------
input bool     InpUseBreakeven       = true;      // Move SL to entry once in profit
input double   InpBreakevenAtrMult   = 1.0;       // Profit (in ATR) before breakeven
input double   InpLockProfitAtrMult  = 0.0;       // Lock SL this much ATR above entry (0=plain breakeven AT entry)
input bool     InpUseTrailing        = true;      // Trail the stop behind price
input double   InpTrailAtrMult       = 2.0;       // Trail distance = ATR x this

//--- Inputs: Multiple entries (scale in) ----------------------------
input bool     InpPyramid            = true;      // Keep adding entries along the trend
input int      InpSpacingBars        = 6;         // Min bars between added entries
input bool     InpReverseOnOpposite  = false;     // Close opposite trades when signal flips

//--- Inputs: GRID mode (stack many trades along the trend) -----------
input bool     InpGridMode           = true;      // Grid ON: rapidly stack entries WITH the trend
input double   InpGridStepPoints     = 100;       // Min price gap (points) between grid entries

//--- Inputs: Close-in-profit (values in ACCOUNT ccy = CENTS on a cent acct)
input bool     InpCloseInProfit      = true;      // Close a position once it shows profit
input double   InpMinProfitMoney     = 10.0;      // Min profit to close one (small = fast banking)
input double   InpBasketProfitMoney  = 0.0;       // Close ALL when total profit >= this (0=off)

//--- Inputs: General ------------------------------------------------
input int      InpMaxOpenPositions   = 8;         // Max simultaneous positions (grid basket size)
input long     InpMagicNumber        = 532023;    // Unique ID for this EA's trades
input int      InpSlippagePoints     = 30;        // Max slippage (points)

//--- Globals --------------------------------------------------------
CTrade        trade;
int           hFastEMA = INVALID_HANDLE;
int           hSlowEMA = INVALID_HANDLE;
int           hRSI     = INVALID_HANDLE;
int           hATR     = INVALID_HANDLE;
int           hADX     = INVALID_HANDLE;
int           hHTFFast = INVALID_HANDLE;
int           hHTFSlow = INVALID_HANDLE;
datetime      g_lastBarTime = 0;
datetime      g_currentDay  = 0;
double        g_dayStartBalance = 0.0;
int           g_barsSinceEntry = 100000;   // large so first entry isn't blocked
double        g_lastGridPrice  = 0.0;      // price of the most recent grid entry

//+------------------------------------------------------------------+
//| Initialisation                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpFastEMA >= InpSlowEMA)
     {
      Print("ERROR: Fast EMA must be smaller than Slow EMA.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   hFastEMA = iMA(_Symbol, _Period, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlowEMA = iMA(_Symbol, _Period, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRSI     = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
   hATR     = iATR(_Symbol, _Period, InpATRPeriod);
   hADX     = iADX(_Symbol, _Period, InpADXPeriod);
   hHTFFast = iMA(_Symbol, InpTrendTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hHTFSlow = iMA(_Symbol, InpTrendTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(hFastEMA == INVALID_HANDLE || hSlowEMA == INVALID_HANDLE ||
      hRSI == INVALID_HANDLE || hATR == INVALID_HANDLE ||
      hADX == INVALID_HANDLE || hHTFFast == INVALID_HANDLE ||
      hHTFSlow == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create indicator handles.");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_currentDay      = StartOfDay(TimeCurrent());
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   PrintFormat("LexiAutoTrader started on %s %s. Risk %.2f%%/trade.",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period), InpRiskPerTradePct);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Cleanup                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hFastEMA != INVALID_HANDLE) IndicatorRelease(hFastEMA);
   if(hSlowEMA != INVALID_HANDLE) IndicatorRelease(hSlowEMA);
   if(hRSI     != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR     != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hADX     != INVALID_HANDLE) IndicatorRelease(hADX);
   if(hHTFFast != INVALID_HANDLE) IndicatorRelease(hHTFFast);
   if(hHTFSlow != INVALID_HANDLE) IndicatorRelease(hHTFSlow);
  }

//+------------------------------------------------------------------+
//| Main tick handler                                                |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Bank earnings on every tick so we close as soon as a trade is in
   // profit; also keep trailing/breakeven responsive.
   TakeProfits();
   ManageOpenPositions();

   // Grid: stack extra entries along the trend on every tick (not just
   // per bar), spaced out by price so a basket builds up like a grid.
   if(InpGridMode)
      TryGridEntry();

   // Everything below (entries) is evaluated once per closed bar.
   datetime barTime = iTime(_Symbol, _Period, 0);
   if(barTime == g_lastBarTime)
      return;
   g_lastBarTime = barTime;
   g_barsSinceEntry++;

   RollDailyBalance();

   int signal = GetSignal();          // +1 buy, -1 sell, 0 hold (fresh cross)
   int trend  = Trend();              // +1 up, -1 down, 0 undecided

   int direction = 0;
   bool isPyramid = false;
   if(signal != 0)
     {
      direction = signal;             // a fresh crossover always counts
      if(InpReverseOnOpposite)
         CloseOppositePositions(signal);
     }
   else if(InpPyramid && trend != 0)
     {
      direction = trend;              // otherwise scale into the trend
      isPyramid = true;
     }

   if(direction == 0)
      return;

   // --- Entry-quality filters: skip choppy / counter-trend setups ----
   // 1) Require a real trend (ADX), not a sideways chop.
   if(InpUseADX && CurrentADX() < InpADXMin)
      return;
   // 2) Only trade in the direction of the higher-timeframe trend.
   if(InpUseHTFTrend)
     {
      int htf = HTFTrend();
      if(htf == 0 || htf != direction)
         return;
     }

   // Space out added (pyramid) entries; a fresh signal is exempt.
   if(isPyramid && g_barsSinceEntry < InpSpacingBars)
      return;

   if(CountMyPositions() >= InpMaxOpenPositions)
      return;

   if(!DailyLossOK())
      return;

   OpenTrade(direction);
   g_barsSinceEntry = 0;
  }

//+------------------------------------------------------------------+
//| Grid: add another entry WITH the trend, spaced out by price       |
//+------------------------------------------------------------------+
void TryGridEntry()
  {
   int n = CountMyPositions();
   if(n == 0)
      g_lastGridPrice = 0.0;        // basket empty -> allow a fresh start
   if(n >= InpMaxOpenPositions)
      return;
   if(!DailyLossOK())
      return;

   int trend = Trend();
   if(trend == 0)
      return;

   // Same trend-quality filters as normal entries.
   if(InpUseADX && CurrentADX() < InpADXMin)
      return;
   if(InpUseHTFTrend)
     {
      int htf = HTFTrend();
      if(htf == 0 || htf != trend)
         return;
     }

   // Only add once price has moved a grid step from the last entry.
   double price = (trend > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                              : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double step  = InpGridStepPoints * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(g_lastGridPrice != 0.0 && MathAbs(price - g_lastGridPrice) < step)
      return;

   OpenTrade(trend);
   g_lastGridPrice = price;
  }

//+------------------------------------------------------------------+
//| Close any position that is in profit (banks earnings)            |
//+------------------------------------------------------------------+
void TakeProfits()
  {
   // Basket mode: close everything once combined profit hits the target.
   if(InpBasketProfitMoney > 0.0)
     {
      double total = 0.0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong t = PositionGetTicket(i);
         if(PositionSelectByTicket(t) &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
            total += PositionGetDouble(POSITION_PROFIT);
        }
      if(total >= InpBasketProfitMoney)
        {
         CloseAllMine();
         PrintFormat("Basket profit %.2f >= %.2f: closed all.", total, InpBasketProfitMoney);
         return;
        }
     }

   if(!InpCloseInProfit)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit > 0.0 && profit >= InpMinProfitMoney)
        {
         if(trade.PositionClose(ticket))
            PrintFormat("Banked #%I64u (P/L %.2f).", ticket, profit);
        }
     }
  }

//+------------------------------------------------------------------+
//| Prevailing trend: fast/slow EMA relationship, RSI-filtered       |
//+------------------------------------------------------------------+
int Trend()
  {
   double fast[1], slow[1], rsi[1];
   if(CopyBuffer(hFastEMA, 0, 1, 1, fast) < 1) return(0);
   if(CopyBuffer(hSlowEMA, 0, 1, 1, slow) < 1) return(0);
   if(CopyBuffer(hRSI,     0, 1, 1, rsi)  < 1) return(0);

   if(fast[0] > slow[0] && rsi[0] < InpRSIOverbought) return(1);
   if(fast[0] < slow[0] && rsi[0] > InpRSIOversold)   return(-1);
   return(0);
  }

//+------------------------------------------------------------------+
//| Close every position owned by this EA                            |
//+------------------------------------------------------------------+
void CloseAllMine()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         trade.PositionClose(ticket);
     }
  }

//+------------------------------------------------------------------+
//| Signal: EMA crossover filtered by RSI, on last CLOSED bar        |
//+------------------------------------------------------------------+
int GetSignal()
  {
   double fast[2], slow[2], rsi[1];

   // shift 1 = last closed bar, shift 2 = the bar before it
   if(CopyBuffer(hFastEMA, 0, 1, 2, fast) < 2) return(0);
   if(CopyBuffer(hSlowEMA, 0, 1, 2, slow) < 2) return(0);
   if(CopyBuffer(hRSI,     0, 1, 1, rsi)  < 1) return(0);

   // CopyBuffer returns oldest-first: index 0 = older bar, 1 = newer.
   double fastPrev = fast[0], fastNow = fast[1];
   double slowPrev = slow[0], slowNow = slow[1];
   double rsiNow   = rsi[0];

   bool crossUp   = (fastPrev <= slowPrev && fastNow > slowNow);
   bool crossDown = (fastPrev >= slowPrev && fastNow < slowNow);

   if(crossUp && rsiNow < InpRSIOverbought)
      return(1);
   if(crossDown && rsiNow > InpRSIOversold)
      return(-1);

   return(0);
  }

//+------------------------------------------------------------------+
//| Open a trade in the given direction                              |
//+------------------------------------------------------------------+
void OpenTrade(const int signal)
  {
   double atr = CurrentATR();
   if(atr <= 0.0)
     {
      Print("ATR unavailable; skipping entry.");
      return;
     }

   double slDist = atr * InpSLAtrMult;
   double tpDist = atr * InpTPAtrMult;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double price, sl, tp;
   if(signal > 0)
     {
      price = ask;
      sl    = NormalizeDouble(price - slDist, digits);
      tp    = NormalizeDouble(price + tpDist, digits);
     }
   else
     {
      price = bid;
      sl    = NormalizeDouble(price + slDist, digits);
      tp    = NormalizeDouble(price - tpDist, digits);
     }

   double lot = CalcLot(slDist);
   if(lot <= 0.0)
      return;

   bool ok;
   if(signal > 0)
      ok = trade.Buy(lot, _Symbol, price, sl, tp, "LexiAutoTrader");
   else
      ok = trade.Sell(lot, _Symbol, price, sl, tp, "LexiAutoTrader");

   if(ok)
      PrintFormat("%s %.2f lots @ %.5f SL=%.5f TP=%.5f",
                  (signal > 0 ? "BUY" : "SELL"), lot, price, sl, tp);
   else
      PrintFormat("Order failed: retcode=%d %s",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Position sizing from risk % and stop distance                    |
//+------------------------------------------------------------------+
double CalcLot(const double slDistance)
  {
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (InpRiskPerTradePct / 100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0 || slDistance <= 0.0)
      return(InpMinLot);

   double lossPerLot = (slDistance / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return(InpMinLot);

   double lot = riskMoney / lossPerLot;

   // Round to the broker's volume step and clamp to all limits.
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double brkMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double brkMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step > 0.0)
      lot = MathFloor(lot / step) * step;

   lot = MathMax(lot, MathMax(InpMinLot, brkMin));
   lot = MathMin(lot, MathMin(InpMaxLot, brkMax));
   return(NormalizeDouble(lot, 2));
  }

//+------------------------------------------------------------------+
//| Manage open positions: breakeven + trailing stop                 |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   if(!InpUseBreakeven && !InpUseTrailing)
      return;

   double atr = CurrentATR();
   if(atr <= 0.0)
      return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long   type   = PositionGetInteger(POSITION_TYPE);
      double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL  = PositionGetDouble(POSITION_SL);
      double tp     = PositionGetDouble(POSITION_TP);
      double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double newSL = curSL;

      if(type == POSITION_TYPE_BUY)
        {
         double profit = bid - entry;
         // Breakeven (+ optional profit lock): once far enough in profit,
         // pull the SL up to entry plus a slice of ATR so a pullback still
         // banks a guaranteed gain.
         if(InpUseBreakeven && profit >= atr * InpBreakevenAtrMult)
            newSL = MathMax(newSL, entry + atr * InpLockProfitAtrMult);
         // Trailing: keep SL a fixed ATR distance behind price.
         if(InpUseTrailing)
           {
            double trail = bid - atr * InpTrailAtrMult;
            if(trail > newSL)
               newSL = trail;
           }
         newSL = NormalizeDouble(newSL, digits);
         if(newSL > curSL && newSL < bid)
            trade.PositionModify(ticket, newSL, tp);
        }
      else if(type == POSITION_TYPE_SELL)
        {
         double profit = entry - ask;
         double beTarget = entry - atr * InpLockProfitAtrMult;
         if(InpUseBreakeven && profit >= atr * InpBreakevenAtrMult)
            newSL = (curSL == 0.0) ? beTarget : MathMin(newSL, beTarget);
         if(InpUseTrailing)
           {
            double trail = ask + atr * InpTrailAtrMult;
            if(curSL == 0.0 || trail < newSL)
               newSL = trail;
           }
         newSL = NormalizeDouble(newSL, digits);
         if((curSL == 0.0 || newSL < curSL) && newSL > ask)
            trade.PositionModify(ticket, newSL, tp);
        }
     }
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double CurrentATR()
  {
   double atr[1];
   if(CopyBuffer(hATR, 0, 1, 1, atr) < 1)
      return(0.0);
   return(atr[0]);
  }

// ADX main line on the last closed bar (trend strength, 0..100).
double CurrentADX()
  {
   double adx[1];
   if(CopyBuffer(hADX, 0, 1, 1, adx) < 1)
      return(0.0);
   return(adx[0]);
  }

// Higher-timeframe trend: +1 up, -1 down, 0 undecided.
int HTFTrend()
  {
   double fast[1], slow[1];
   if(CopyBuffer(hHTFFast, 0, 1, 1, fast) < 1) return(0);
   if(CopyBuffer(hHTFSlow, 0, 1, 1, slow) < 1) return(0);
   if(fast[0] > slow[0]) return(1);
   if(fast[0] < slow[0]) return(-1);
   return(0);
  }

int CountMyPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         count++;
     }
   return(count);
  }

void CloseOppositePositions(const int signal)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      bool opposite = (type == POSITION_TYPE_BUY  && signal < 0) ||
                      (type == POSITION_TYPE_SELL && signal > 0);
      if(opposite)
         trade.PositionClose(ticket);
     }
  }

datetime StartOfDay(const datetime t)
  {
   MqlDateTime st;
   TimeToStruct(t, st);
   st.hour = 0; st.min = 0; st.sec = 0;
   return(StructToTime(st));
  }

void RollDailyBalance()
  {
   datetime today = StartOfDay(TimeCurrent());
   if(today != g_currentDay)
     {
      g_currentDay      = today;
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      PrintFormat("New trading day. Start balance = %.2f", g_dayStartBalance);
     }
  }

bool DailyLossOK()
  {
   if(g_dayStartBalance <= 0.0)
      return(true);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct = (g_dayStartBalance - equity) / g_dayStartBalance * 100.0;
   if(lossPct >= InpMaxDailyLossPct)
     {
      static datetime warned = 0;
      if(warned != g_currentDay)
        {
         PrintFormat("Daily loss limit hit (%.2f%%). No new trades today.", lossPct);
         warned = g_currentDay;
        }
      return(false);
     }
   return(true);
  }
//+------------------------------------------------------------------+
