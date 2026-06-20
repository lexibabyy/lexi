//+------------------------------------------------------------------+
//|                                                      LexiSMC.mq5  |
//|   Smart-Money-Concept Expert Advisor (NOT a grid / martingale)   |
//|                                                                  |
//|   - Trades only after market-structure confirmation.            |
//|   - Scales into WINNERS only; NEVER adds to a losing trade.      |
//|   - Confidence 0-100 (5 x 20); trades only when >= 80.          |
//|   - TP ladder 1R/2R/3R (25% each) + trailing runner, BE after TP1|
//|   - Risk: 0.5%/entry, 2% cycle, 3% daily, 8% weekly, 10% kill,   |
//|     pause after 3 consecutive losing ideas.                     |
//|                                                                  |
//|   Attach to BTCUSD (works on any symbol). Test on DEMO first.    |
//|   Trading is high-risk. No profit guaranteed. Not advice.       |
//+------------------------------------------------------------------+
#property copyright "Lexi"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//--- Timeframes -----------------------------------------------------
input ENUM_TIMEFRAMES InpTrendTF   = PERIOD_H4;   // HTF trend filter
input ENUM_TIMEFRAMES InpEntryTF   = PERIOD_M15;  // Structure / entry timeframe

//--- Indicators -----------------------------------------------------
input int    InpEmaFast      = 50;    // Trend fast EMA (on HTF)
input int    InpEmaSlow      = 200;   // Trend slow EMA (on HTF)
input int    InpRSIPeriod    = 14;    // RSI period
input int    InpATRPeriod    = 14;    // ATR period
input int    InpSwingLookback= 3;     // Fractal half-window for swings
input int    InpScanBars     = 120;   // How many bars to scan for structure

//--- Confidence -----------------------------------------------------
input double InpMinConfidence= 80.0;  // Min score (0-100) to trade

//--- Risk (percent of equity) --------------------------------------
input double InpRiskPerEntry = 0.5;   // % risk per entry
input double InpMaxCycleRisk = 2.0;   // % max per trade idea (4 entries)
input double InpMaxDailyDD    = 3.0;  // % daily drawdown -> stop for day
input double InpMaxWeeklyDD   = 8.0;  // % weekly drawdown -> stop for week
input double InpEmergencyDD   = 10.0; // % drawdown from peak -> hard stop
input int    InpMaxConsecLoss = 3;    // Pause after this many losing ideas

//--- Volatility / sanity filters -----------------------------------
input double InpVolMult       = 1.3;  // Volume must exceed avg x this
input double InpMinATRpct     = 0.0008;// Skip if ATR < this fraction of price
input double InpMaxATRpct     = 0.05; // Skip if ATR > this fraction of price
input int    InpMaxSpreadPts  = 200;  // Skip if spread (points) above this

//--- Take profit ----------------------------------------------------
input double InpTP1R          = 1.0;  // TP1 at R multiple
input double InpTP2R          = 2.0;  // TP2 at R multiple
input double InpTP3R          = 3.0;  // TP3 at R multiple
input double InpTPfraction    = 0.25; // Fraction closed at each TP

//--- General --------------------------------------------------------
input long   InpMagic        = 870125;// Unique EA id
input int    InpSlippagePts  = 50;    // Max slippage (points)
input bool   InpVerbose      = true;  // Print analysis to the Experts log each bar

//--- Globals --------------------------------------------------------
CTrade   trade;
int      hEmaFast = INVALID_HANDLE, hEmaSlow = INVALID_HANDLE;
int      hRSI = INVALID_HANDLE, hATR = INVALID_HANDLE;

datetime g_lastBar = 0;
datetime g_day = 0;
int      g_week = -1;
double   g_dayStartEq = 0.0, g_weekStartEq = 0.0, g_peakEq = 0.0;
int      g_consec = 0;
bool     g_emergency = false, g_haltDay = false, g_haltWeek = false;

// current trade idea
bool     g_inIdea = false;
int      g_side = 0;            // +1 long, -1 short
double   g_sl = 0.0;           // shared stop for the basket
double   g_R  = 0.0;           // 1R distance (price)
double   g_cycleRisk = 0.0;    // % risk committed in this idea
int      g_entries = 0;
bool     g_tp1 = false, g_tp2 = false, g_tp3 = false;
double   g_ideaStartBalance = 0.0;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpEmaFast >= InpEmaSlow)
     {
      Print("ERROR: Fast EMA must be < Slow EMA");
      return(INIT_PARAMETERS_INCORRECT);
     }
   hEmaFast = iMA(_Symbol, InpTrendTF, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow = iMA(_Symbol, InpTrendTF, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hRSI     = iRSI(_Symbol, InpEntryTF, InpRSIPeriod, PRICE_CLOSE);
   hATR     = iATR(_Symbol, InpEntryTF, InpATRPeriod);
   if(hEmaFast==INVALID_HANDLE || hEmaSlow==INVALID_HANDLE ||
      hRSI==INVALID_HANDLE || hATR==INVALID_HANDLE)
     {
      Print("ERROR: indicator handles failed");
      return(INIT_FAILED);
     }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   g_peakEq = eq; g_dayStartEq = eq; g_weekStartEq = eq;
   g_day = StartOfDay(TimeCurrent());
   g_week = WeekIndex(TimeCurrent());
   PrintFormat("LexiSMC started on %s entryTF=%s trendTF=%s",
               _Symbol, EnumToString(InpEntryTF), EnumToString(InpTrendTF));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(hEmaFast!=INVALID_HANDLE) IndicatorRelease(hEmaFast);
   if(hEmaSlow!=INVALID_HANDLE) IndicatorRelease(hEmaSlow);
   if(hRSI!=INVALID_HANDLE)     IndicatorRelease(hRSI);
   if(hATR!=INVALID_HANDLE)     IndicatorRelease(hATR);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // Manage open basket every tick (TPs, breakeven, trailing).
   if(CountMyPositions() > 0)
      ManageBasket();
   else if(g_inIdea)
      FinalizeIdea();             // basket fully closed -> tally result

   // Per-bar logic on the entry timeframe.
   datetime bt = iTime(_Symbol, InpEntryTF, 0);
   if(bt == g_lastBar) return;
   g_lastBar = bt;

   RollDayWeek();
   UpdateRiskMarks();

   if(g_side == 0)
     {
      if(InpVerbose) LogDiagnostics();
      TryEnter();
     }
   else
      TryScaleIn();
  }

//+------------------------------------------------------------------+
//| Per-bar diagnostics so you can see WHY it is or isn't trading     |
//+------------------------------------------------------------------+
void LogDiagnostics()
  {
   int trend = HtfTrend();
   string tname = (trend>0 ? "UP" : trend<0 ? "DOWN" : "NONE");
   double conf = (trend!=0) ? Confidence(trend) : 0.0;

   bool sweep = (trend>0) ? SweepBullish() : (trend<0 ? SweepBearish() : false);
   bool div   = (trend>0) ? DivBullish()   : (trend<0 ? DivBearish()   : false);
   bool choch = (trend>0) ? ChochBullish() : (trend<0 ? ChochBearish() : false);
   bool bos   = (trend>0) ? BosBullish()   : (trend<0 ? BosBearish()   : false);

   PrintFormat("SMC scan: trend=%s conf=%.0f/%.0f | sweep=%d div=%d choch=%d bos=%d vol=%d | volOK=%s spread=%d canOpen=%s",
               tname, conf, InpMinConfidence,
               (int)sweep, (int)div, (int)choch, (int)bos, (int)VolumeOK(),
               (VolatilityOK()?"yes":"no"), SpreadPoints(),
               (CanOpenNewIdea()?"yes":"no"));
  }

//+------------------------------------------------------------------+
//| ENTRY: full SMC confirmation + confidence >= threshold           |
//+------------------------------------------------------------------+
void TryEnter()
  {
   if(!CanOpenNewIdea())          return;
   if(!VolatilityOK())            return;
   if(SpreadPoints() > InpMaxSpreadPts) return;

   int trend = HtfTrend();        // +1 up, -1 down, 0 none
   if(trend == 0) return;

   int side = trend;              // only trade WITH the HTF trend
   double conf = Confidence(side);
   if(conf < InpMinConfidence) return;

   double price = (side>0) ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                           : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double sl = (side>0) ? RecentSwingLowPrice() : RecentSwingHighPrice();
   if(sl<=0.0) return;
   if((side>0 && sl>=price) || (side<0 && sl<=price)) return;

   double slDist = MathAbs(price - sl);
   double lot = CalcLot(slDist);
   if(lot <= 0.0) return;

   bool ok = (side>0) ? trade.Buy(lot,_Symbol,price,sl,0.0,"LexiSMC")
                      : trade.Sell(lot,_Symbol,price,sl,0.0,"LexiSMC");
   if(!ok)
     {
      PrintFormat("Entry failed: %d %s", trade.ResultRetcode(),
                  trade.ResultRetcodeDescription());
      return;
     }
   g_inIdea = true; g_side = side; g_sl = sl; g_R = slDist;
   g_entries = 1; g_cycleRisk = InpRiskPerEntry;
   g_tp1=false; g_tp2=false; g_tp3=false;
   g_ideaStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   PrintFormat("OPEN %s conf=%.0f lot=%.2f @ %.2f SL=%.2f (1R=%.2f)",
               (side>0?"LONG":"SHORT"), conf, lot, price, sl, slDist);
  }

//+------------------------------------------------------------------+
//| SCALE-IN: add to WINNERS only, on a fresh in-trend BOS           |
//+------------------------------------------------------------------+
void TryScaleIn()
  {
   if(g_entries >= 4)            return;
   if(g_tp3)                     return;          // no adds once nearly done
   if(g_cycleRisk + InpRiskPerEntry > InpMaxCycleRisk + 1e-9) return;
   if(HtfTrend() != g_side)      return;

   double avg = MyAvgEntry();
   double price = (g_side>0) ? SymbolInfoDouble(_Symbol,SYMBOL_BID)
                             : SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   bool inProfit = (g_side>0) ? (price > avg) : (price < avg);
   if(!inProfit)                 return;          // never add to a loser

   bool freshBOS = (g_side>0) ? BosBullish() : BosBearish();
   if(!freshBOS)                 return;

   double entry = (g_side>0) ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                             : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double lot = CalcLot(MathAbs(entry - g_sl));
   if(lot <= 0.0)                return;

   bool ok = (g_side>0) ? trade.Buy(lot,_Symbol,entry,g_sl,0.0,"LexiSMC-add")
                        : trade.Sell(lot,_Symbol,entry,g_sl,0.0,"LexiSMC-add");
   if(ok)
     {
      g_entries++; g_cycleRisk += InpRiskPerEntry;
      PrintFormat("ADD #%d lot=%.2f @ %.2f", g_entries, lot, entry);
     }
  }

//+------------------------------------------------------------------+
//| MANAGE: TP ladder, breakeven, trailing                           |
//+------------------------------------------------------------------+
void ManageBasket()
  {
   double avg = MyAvgEntry();
   if(avg<=0.0 || g_R<=0.0) return;
   double price = (g_side>0) ? SymbolInfoDouble(_Symbol,SYMBOL_BID)
                             : SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double profitR = (g_side>0) ? (price-avg)/g_R : (avg-price)/g_R;

   if(!g_tp1 && profitR >= InpTP1R)
     {
      CloseFraction(InpTPfraction);
      g_tp1 = true;
      g_sl = avg;                       // move stop to breakeven
      SetBasketSL(g_sl);
      Print("TP1 hit: 25% closed, SL -> breakeven");
     }
   if(!g_tp2 && profitR >= InpTP2R)
     {
      CloseFraction(InpTPfraction); g_tp2 = true; Print("TP2 hit: 25% closed");
     }
   if(!g_tp3 && profitR >= InpTP3R)
     {
      CloseFraction(InpTPfraction); g_tp3 = true; Print("TP3 hit: 25% closed");
     }
   if(g_tp3)                              // trail the runner with ATR
     {
      double atr = CurrentATR();
      if(atr > 0.0)
        {
         double trail = (g_side>0) ? price-atr : price+atr;
         if((g_side>0 && trail>g_sl) || (g_side<0 && (g_sl==0.0 || trail<g_sl)))
           { g_sl = trail; SetBasketSL(g_sl); }
        }
     }
  }

//+------------------------------------------------------------------+
//| Idea finished (basket empty): tally win/loss, update streak      |
//+------------------------------------------------------------------+
void FinalizeIdea()
  {
   double pnl = AccountInfoDouble(ACCOUNT_BALANCE) - g_ideaStartBalance;
   if(pnl < 0.0) g_consec++; else g_consec = 0;
   PrintFormat("IDEA CLOSED pnl=%.2f consecutiveLosses=%d", pnl, g_consec);
   g_inIdea=false; g_side=0; g_sl=0; g_R=0; g_cycleRisk=0; g_entries=0;
   g_tp1=g_tp2=g_tp3=false;
  }

//+==================================================================+
//|  STRUCTURE / SMC DETECTION (heuristic)                           |
//+==================================================================+
// Return shift of the rank-th most recent swing high (0=most recent).
int SwingHighShift(int rank)
  {
   int L=InpSwingLookback, found=0;
   for(int k=L; k<=InpScanBars-L; k++)
     {
      double h=iHigh(_Symbol,InpEntryTF,k);
      bool sw=true;
      for(int j=1;j<=L;j++)
         if(iHigh(_Symbol,InpEntryTF,k-j)>=h || iHigh(_Symbol,InpEntryTF,k+j)>=h)
           { sw=false; break; }
      if(sw){ if(found==rank) return k; found++; }
     }
   return -1;
  }

int SwingLowShift(int rank)
  {
   int L=InpSwingLookback, found=0;
   for(int k=L; k<=InpScanBars-L; k++)
     {
      double lo=iLow(_Symbol,InpEntryTF,k);
      bool sw=true;
      for(int j=1;j<=L;j++)
         if(iLow(_Symbol,InpEntryTF,k-j)<=lo || iLow(_Symbol,InpEntryTF,k+j)<=lo)
           { sw=false; break; }
      if(sw){ if(found==rank) return k; found++; }
     }
   return -1;
  }

double RecentSwingHighPrice(){ int s=SwingHighShift(0); return s<0?0.0:iHigh(_Symbol,InpEntryTF,s); }
double RecentSwingLowPrice(){  int s=SwingLowShift(0);  return s<0?0.0:iLow(_Symbol,InpEntryTF,s); }

bool BosBullish(){ int s=SwingHighShift(0); return s>0 && iClose(_Symbol,InpEntryTF,1) > iHigh(_Symbol,InpEntryTF,s); }
bool BosBearish(){ int s=SwingLowShift(0);  return s>0 && iClose(_Symbol,InpEntryTF,1) < iLow(_Symbol,InpEntryTF,s); }

bool SweepBullish()
  {
   int s=SwingLowShift(0); if(s<0) return false;
   double lvl=iLow(_Symbol,InpEntryTF,s);
   return iLow(_Symbol,InpEntryTF,1) < lvl && iClose(_Symbol,InpEntryTF,1) > lvl;
  }
bool SweepBearish()
  {
   int s=SwingHighShift(0); if(s<0) return false;
   double lvl=iHigh(_Symbol,InpEntryTF,s);
   return iHigh(_Symbol,InpEntryTF,1) > lvl && iClose(_Symbol,InpEntryTF,1) < lvl;
  }

bool ChochBullish()
  {
   int h0=SwingHighShift(0), h1=SwingHighShift(1);
   int l0=SwingLowShift(0),  l1=SwingLowShift(1);
   if(h0<0||h1<0||l0<0||l1<0) return false;
   bool down = iHigh(_Symbol,InpEntryTF,h0)<iHigh(_Symbol,InpEntryTF,h1) &&
               iLow(_Symbol,InpEntryTF,l0)<iLow(_Symbol,InpEntryTF,l1);
   return down && iClose(_Symbol,InpEntryTF,1) > iHigh(_Symbol,InpEntryTF,h0);
  }
bool ChochBearish()
  {
   int h0=SwingHighShift(0), h1=SwingHighShift(1);
   int l0=SwingLowShift(0),  l1=SwingLowShift(1);
   if(h0<0||h1<0||l0<0||l1<0) return false;
   bool up = iHigh(_Symbol,InpEntryTF,h0)>iHigh(_Symbol,InpEntryTF,h1) &&
             iLow(_Symbol,InpEntryTF,l0)>iLow(_Symbol,InpEntryTF,l1);
   return up && iClose(_Symbol,InpEntryTF,1) < iLow(_Symbol,InpEntryTF,l0);
  }

bool DivBullish()
  {
   int l0=SwingLowShift(0), l1=SwingLowShift(1);
   if(l0<0||l1<0) return false;
   bool lowerLow = iLow(_Symbol,InpEntryTF,l0) < iLow(_Symbol,InpEntryTF,l1);
   return lowerLow && (RSIat(l0) > RSIat(l1));
  }
bool DivBearish()
  {
   int h0=SwingHighShift(0), h1=SwingHighShift(1);
   if(h0<0||h1<0) return false;
   bool higherHigh = iHigh(_Symbol,InpEntryTF,h0) > iHigh(_Symbol,InpEntryTF,h1);
   return higherHigh && (RSIat(h0) < RSIat(h1));
  }

bool VolumeOK()
  {
   long v[]; ArraySetAsSeries(v,true);
   if(CopyTickVolume(_Symbol,InpEntryTF,0,22,v) < 22) return false;
   double avg=0.0; for(int i=2;i<=21;i++) avg += (double)v[i]; avg/=20.0;
   return ((double)v[1] >= InpVolMult*avg);
  }

// Confidence 0-100: five 20-point confluence checks.
double Confidence(int side)
  {
   double s=0.0;
   if(side>0)
     {
      if(SweepBullish()) s+=20;
      if(DivBullish())   s+=20;
      if(ChochBullish()) s+=20;
      if(BosBullish())   s+=20;
      if(VolumeOK())     s+=20;
     }
   else
     {
      if(SweepBearish()) s+=20;
      if(DivBearish())   s+=20;
      if(ChochBearish()) s+=20;
      if(BosBearish())   s+=20;
      if(VolumeOK())     s+=20;
     }
   return s;
  }

//+==================================================================+
//|  HELPERS                                                         |
//+==================================================================+
int HtfTrend()
  {
   double f[1], sd[1];
   if(CopyBuffer(hEmaFast,0,1,1,f)<1)  return 0;
   if(CopyBuffer(hEmaSlow,0,1,1,sd)<1) return 0;
   if(f[0] > sd[0]) return 1;
   if(f[0] < sd[0]) return -1;
   return 0;
  }

double RSIat(int shift)
  {
   double b[1];
   if(CopyBuffer(hRSI,0,shift,1,b)<1) return 50.0;
   return b[0];
  }

double CurrentATR()
  {
   double a[1];
   if(CopyBuffer(hATR,0,1,1,a)<1) return 0.0;
   return a[0];
  }

bool VolatilityOK()
  {
   double atr=CurrentATR();
   double price=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(atr<=0.0 || price<=0.0) return false;
   double p=atr/price;
   return (p>=InpMinATRpct && p<=InpMaxATRpct);
  }

int SpreadPoints()
  {
   return (int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
  }

double CalcLot(double slDist)
  {
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney=eq*(InpRiskPerEntry/100.0);
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tv<=0.0||ts<=0.0||slDist<=0.0) return 0.0;
   double lossPerLot=(slDist/ts)*tv;
   if(lossPerLot<=0.0) return 0.0;
   double lot=riskMoney/lossPerLot;
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(step>0.0) lot=MathFloor(lot/step)*step;
   lot=MathMax(lot,vmin);
   lot=MathMin(lot,vmax);
   return NormalizeDouble(lot,2);
  }

double NormalizeVolume(double v)
  {
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step>0.0) v=MathFloor(v/step)*step;
   return NormalizeDouble(v,2);
  }

int CountMyPositions()
  {
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t) &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic &&
         PositionGetString(POSITION_SYMBOL)==_Symbol) c++;
     }
   return c;
  }

double MyVolume()
  {
   double v=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t) &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic &&
         PositionGetString(POSITION_SYMBOL)==_Symbol)
         v+=PositionGetDouble(POSITION_VOLUME);
     }
   return v;
  }

double MyAvgEntry()
  {
   double vol=0.0, num=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t) &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic &&
         PositionGetString(POSITION_SYMBOL)==_Symbol)
        {
         double pv=PositionGetDouble(POSITION_VOLUME);
         num+=PositionGetDouble(POSITION_PRICE_OPEN)*pv;
         vol+=pv;
        }
     }
   return (vol>0.0)? num/vol : 0.0;
  }

void CloseFraction(double frac)
  {
   double toClose=NormalizeVolume(MyVolume()*frac);
   if(toClose<=0.0) return;
   for(int i=PositionsTotal()-1;i>=0 && toClose>0.0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      double pv=PositionGetDouble(POSITION_VOLUME);
      double c=NormalizeVolume(MathMin(pv,toClose));
      if(c<=0.0) continue;
      if(c>=pv) trade.PositionClose(t);
      else      trade.PositionClosePartial(t,c);
      toClose-=c;
     }
  }

void SetBasketSL(double level)
  {
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long type=PositionGetInteger(POSITION_TYPE);
      double tp=PositionGetDouble(POSITION_TP);
      double cur=PositionGetDouble(POSITION_SL);
      if(type==POSITION_TYPE_BUY && level<bid && level!=cur)
         trade.PositionModify(t,level,tp);
      if(type==POSITION_TYPE_SELL && level>ask && level!=cur)
         trade.PositionModify(t,level,tp);
     }
  }

//+==================================================================+
//|  RISK GATES                                                      |
//+==================================================================+
bool CanOpenNewIdea()
  {
   if(g_emergency){ static datetime w=0; if(w!=g_day){Print("EMERGENCY stop active"); w=g_day;} return false; }
   if(g_haltWeek) return false;
   if(g_haltDay)  return false;
   if(g_consec>=InpMaxConsecLoss) return false;
   return true;
  }

void UpdateRiskMarks()
  {
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq>g_peakEq) g_peakEq=eq;
   if(g_peakEq>0.0 && (g_peakEq-eq)/g_peakEq*100.0 >= InpEmergencyDD) g_emergency=true;
   if(g_dayStartEq>0.0 && (g_dayStartEq-eq)/g_dayStartEq*100.0 >= InpMaxDailyDD) g_haltDay=true;
   if(g_weekStartEq>0.0 && (g_weekStartEq-eq)/g_weekStartEq*100.0 >= InpMaxWeeklyDD) g_haltWeek=true;
  }

void RollDayWeek()
  {
   datetime today=StartOfDay(TimeCurrent());
   if(today!=g_day)
     {
      g_day=today; g_dayStartEq=AccountInfoDouble(ACCOUNT_EQUITY);
      g_haltDay=false; g_consec=0;          // fresh day, reset streak pause
     }
   int wk=WeekIndex(TimeCurrent());
   if(wk!=g_week)
     {
      g_week=wk; g_weekStartEq=AccountInfoDouble(ACCOUNT_EQUITY);
      g_haltWeek=false;
     }
  }

datetime StartOfDay(datetime t)
  {
   MqlDateTime s; TimeToStruct(t,s);
   s.hour=0; s.min=0; s.sec=0;
   return StructToTime(s);
  }

int WeekIndex(datetime t)
  {
   MqlDateTime s; TimeToStruct(t,s);
   return s.year*54 + (s.day_of_year/7);
  }
//+------------------------------------------------------------------+
