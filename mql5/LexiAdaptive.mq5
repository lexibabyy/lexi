//+------------------------------------------------------------------+
//|                                                 LexiAdaptive.mq5  |
//|   Adaptive dual-confidence Smart-Money EA for BTCUSD             |
//|                                                                  |
//|   - Two independent scores (Bullish / Bearish, 0-100). Bias is   |
//|     always the stronger side; it can flip instantly.            |
//|   - Aggressive opportunity capture; scales into WINNERS only.    |
//|   - NEVER averages down, NEVER defends losers, no martingale,    |
//|     no fixed grid. Cuts losers fast, banks small profits.       |
//|   - Risk: 0.25%/entry, 5% max exposure, 5% daily, 10% weekly,    |
//|     15% emergency, pause after 5 consecutive losing deals.      |
//|   - On-chart dashboard.                                          |
//|                                                                  |
//|   Attach to BTCUSD. TEST ON DEMO FIRST. High risk, no guarantee. |
//+------------------------------------------------------------------+
#property copyright "Lexi"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//--- Timeframe ------------------------------------------------------
input ENUM_TIMEFRAMES InpTF = PERIOD_M5;   // Working timeframe

//--- Trend EMAs -----------------------------------------------------
input int    InpEma1 = 20;      // Fast EMA
input int    InpEma2 = 50;      // Mid EMA
input int    InpEma3 = 200;     // Slow EMA

//--- Indicators -----------------------------------------------------
input int    InpRSIPeriod    = 14;   // RSI period
input int    InpATRPeriod    = 14;   // ATR period
input int    InpSwingLookback= 3;    // Fractal half-window
input int    InpScanBars     = 90;   // Bars scanned for structure
input double InpVolMult      = 1.2;  // Volume vs average multiplier

//--- Confidence / bias ---------------------------------------------
input double InpEntryConfidence = 55.0;  // Min bias confidence to enter
input double InpAddConfStep     = 6.0;   // Confidence must rise this much to add
input double InpFlipMargin      = 10.0;  // Opposite must beat current by this to flip
input double InpExitConfidence  = 40.0;  // Below this, start exiting that side

//--- Position building / risk --------------------------------------
input double InpBaseRiskPct  = 0.25;  // % risk per entry
input double InpMaxRiskMult   = 2.0;  // Max size multiplier at high confidence
input double InpMaxExposure   = 5.0;  // % max total open risk
input double InpSLAtrMult     = 2.0;  // Stop-loss = ATR x this
input double InpTrailAtrMult  = 1.5;  // ATR trailing distance

//--- Quick profit (bank small gains to dodge pullbacks) ------------
input bool   InpQuickClose       = true;  // Close a position once it shows small profit
input double InpQuickProfitMoney = 1.0;   // Profit (account ccy) to bank a position

//--- Drawdown protection -------------------------------------------
input double InpMaxDailyDD    = 5.0;   // % daily drawdown stop
input double InpMaxWeeklyDD   = 10.0;  // % weekly drawdown stop
input double InpEmergencyDD   = 15.0;  // % from peak -> close all & halt
input int    InpMaxConsecLoss = 5;     // Pause after N consecutive losing deals

//--- Failsafe -------------------------------------------------------
input double InpMaxSpreadPct  = 0.06;  // Skip new trades if spread > this % of price
input int    InpMaxSpreadPts  = 300;   // (reference only; pct gate is used)
input double InpMinMarginLevel= 200.0; // Skip new trades below this margin %

//--- General --------------------------------------------------------
input long   InpMagic        = 990125;
input int    InpSlippagePts  = 50;
input bool   InpDashboard    = true;

//--- Globals --------------------------------------------------------
CTrade   trade;
int      hE1=INVALID_HANDLE, hE2=INVALID_HANDLE, hE3=INVALID_HANDLE;
int      hRSI=INVALID_HANDLE, hATR=INVALID_HANDLE;

datetime g_day=0; int g_week=-1;
double   g_dayStartEq=0, g_weekStartEq=0, g_peakEq=0;
int      g_consec=0;
bool     g_emergency=false, g_haltDay=false, g_haltWeek=false;

int      g_side=0;            // +1 long basket, -1 short basket, 0 flat
double   g_lastAddConf=0.0;   // confidence at the last add
double   g_bull=0.0, g_bear=0.0;
string   g_status="init";

//+------------------------------------------------------------------+
int OnInit()
  {
   hE1 = iMA(_Symbol,InpTF,InpEma1,0,MODE_EMA,PRICE_CLOSE);
   hE2 = iMA(_Symbol,InpTF,InpEma2,0,MODE_EMA,PRICE_CLOSE);
   hE3 = iMA(_Symbol,InpTF,InpEma3,0,MODE_EMA,PRICE_CLOSE);
   hRSI= iRSI(_Symbol,InpTF,InpRSIPeriod,PRICE_CLOSE);
   hATR= iATR(_Symbol,InpTF,InpATRPeriod);
   if(hE1==INVALID_HANDLE||hE2==INVALID_HANDLE||hE3==INVALID_HANDLE||
      hRSI==INVALID_HANDLE||hATR==INVALID_HANDLE)
     { Print("ERROR: indicator handles failed"); return(INIT_FAILED); }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);

   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   g_peakEq=eq; g_dayStartEq=eq; g_weekStartEq=eq;
   g_day=StartOfDay(TimeCurrent()); g_week=WeekIndex(TimeCurrent());
   PrintFormat("LexiAdaptive started on %s %s", _Symbol, EnumToString(InpTF));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(hE1!=INVALID_HANDLE) IndicatorRelease(hE1);
   if(hE2!=INVALID_HANDLE) IndicatorRelease(hE2);
   if(hE3!=INVALID_HANDLE) IndicatorRelease(hE3);
   if(hRSI!=INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR!=INVALID_HANDLE) IndicatorRelease(hATR);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Tally consecutive losses from each closing deal                  |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &req,
                        const MqlTradeResult &res)
  {
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   ulong deal=trans.deal;
   if(!HistoryDealSelect(deal)) return;
   if(HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagic) return;
   if(HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol) return;
   if(HistoryDealGetInteger(deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT) return;
   double pnl=HistoryDealGetDouble(deal,DEAL_PROFIT)
             +HistoryDealGetDouble(deal,DEAL_SWAP)
             +HistoryDealGetDouble(deal,DEAL_COMMISSION);
   if(pnl<0.0) g_consec++;
   else if(pnl>0.0) g_consec=0;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) { g_status="no connection"; return; }

   RollDayWeek();
   UpdateRiskMarks();

   // Emergency: close everything and stop.
   if(g_emergency)
     {
      CloseAll(); g_status="EMERGENCY halt"; UpdateDashboard(); return;
     }

   // Continuous analysis.
   g_bull = BullConfidence();
   g_bear = BearConfidence();
   int bias = Bias();

   // Always-on management first.
   if(InpQuickClose) QuickCloseProfits();
   ManageExits(bias);

   // New activity (entries / adds / reversal).
   if(CanTrade())
      EngineStep(bias);

   if(InpDashboard) UpdateDashboard();
  }

//+==================================================================+
//|  ENTRY / SCALE / REVERSAL ENGINE                                 |
//+==================================================================+
void EngineStep(int bias)
  {
   double conf = (bias>0) ? g_bull : (bias<0 ? g_bear : 0.0);
   if(bias==0 || conf < InpEntryConfidence) { g_status="waiting"; return; }

   int held = NetSide();   // side currently held (+1/-1/0)

   // Bias reversal: opposite side now favoured while we hold the other.
   if(held!=0 && bias!=held)
     {
      CloseSide(held);       // exit the old side (cuts losers, frees winners)
      g_side=0;
     }

   // Open first position of a fresh bias.
   if(NetSide()==0)
     {
      if(OpenEntry(bias, conf))
        { g_side=bias; g_lastAddConf=conf; g_status="opened"; }
      return;
     }

   // Scale into a WINNER only: confidence rising + basket green + room.
   if(NetSide()==bias)
     {
      bool rising  = conf >= g_lastAddConf + InpAddConfStep;
      bool inProfit= BasketProfit() > 0.0;
      if(rising && inProfit && ExposurePct() < InpMaxExposure)
        {
         if(OpenEntry(bias, conf)) { g_lastAddConf=conf; g_status="added"; }
        }
      else
         g_status="holding";
     }
  }

bool OpenEntry(int side, double conf)
  {
   if(SpreadPct() > InpMaxSpreadPct) return false;
   if(MarginLevel() < InpMinMarginLevel && PositionsExistAny()) return false;

   double atr=CurrentATR();
   if(atr<=0.0) return false;
   double price=(side>0)?SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                        :SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double slDist=atr*InpSLAtrMult;
   double sl=(side>0)?price-slDist:price+slDist;

   // size grows with confidence, capped; exposure respected
   double mult=MathMin(InpMaxRiskMult, MathMax(1.0, conf/InpEntryConfidence));
   double riskPct=InpBaseRiskPct*mult;
   if(ExposurePct()+riskPct > InpMaxExposure) riskPct=InpMaxExposure-ExposurePct();
   if(riskPct<=0.01) return false;

   double lot=CalcLot(slDist, riskPct);
   if(lot<=0.0) return false;

   bool ok=(side>0)?trade.Buy(lot,_Symbol,price,sl,0.0,"LexiAdaptive")
                   :trade.Sell(lot,_Symbol,price,sl,0.0,"LexiAdaptive");
   if(!ok)
      PrintFormat("entry failed %d %s",trade.ResultRetcode(),trade.ResultRetcodeDescription());
   return ok;
  }

//+==================================================================+
//|  EXITS                                                           |
//+==================================================================+
// Bank any position that shows the small target profit.
void QuickCloseProfits()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetDouble(POSITION_PROFIT) >= InpQuickProfitMoney)
         trade.PositionClose(t);
     }
  }

// Dynamic exits: ATR trail, breakeven, momentum/structure failure.
void ManageExits(int bias)
  {
   double atr=CurrentATR();
   if(atr<=0.0) return;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;

      long type=PositionGetInteger(POSITION_TYPE);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);

      if(type==POSITION_TYPE_BUY)
        {
         double newSL=sl;
         if(bid-entry > atr) newSL=MathMax(newSL,entry);          // breakeven
         double trail=bid-atr*InpTrailAtrMult;
         if(trail>newSL) newSL=trail;                              // trail
         if(newSL>sl && newSL<bid) trade.PositionModify(t,NormalizeDouble(newSL,_Digits),tp);
        }
      else if(type==POSITION_TYPE_SELL)
        {
         double newSL=sl;
         if(entry-ask > atr) newSL=(sl==0.0)?entry:MathMin(newSL,entry);
         double trail=ask+atr*InpTrailAtrMult;
         if(sl==0.0 || trail<newSL) newSL=trail;
         if((sl==0.0 || newSL<sl) && newSL>ask) trade.PositionModify(t,NormalizeDouble(newSL,_Digits),tp);
        }
     }

   // Structure/confidence failure on the side we hold -> exit it.
   int held=NetSide();
   if(held>0 && (g_bull<InpExitConfidence || BosBearish() || ChochBearish()))
      CloseSide(1);
   if(held<0 && (g_bear<InpExitConfidence || BosBullish() || ChochBullish()))
      CloseSide(-1);
  }

//+==================================================================+
//|  DUAL CONFIDENCE MODEL                                           |
//+==================================================================+
double BullConfidence()
  {
   double e1=EMA(hE1), e2=EMA(hE2), e3=EMA(hE3);
   double r=RSIval();
   double s=0.0;
   // Trend alignment (20)
   if(e1>e2 && e2>e3) s+=20; else if(e1>e2) s+=10;
   // Market structure HH/HL (15)
   if(StructureUp()) s+=15; else if(BosBullish()) s+=7;
   // BOS (15) / CHoCH (10)
   if(BosBullish())   s+=15;
   if(ChochBullish()) s+=10;
   // Momentum (15)
   if(r>55) s+=15; else if(r>50) s+=8;
   // Volume (10) / Volatility (5) / Retest (10)
   if(VolumeOK())     s+=10;
   if(VolatilityOK()) s+=5;
   if(RetestBull())   s+=10;
   return MathMin(100.0,s);
  }

double BearConfidence()
  {
   double e1=EMA(hE1), e2=EMA(hE2), e3=EMA(hE3);
   double r=RSIval();
   double s=0.0;
   if(e1<e2 && e2<e3) s+=20; else if(e1<e2) s+=10;
   if(StructureDown()) s+=15; else if(BosBearish()) s+=7;
   if(BosBearish())   s+=15;
   if(ChochBearish()) s+=10;
   if(r<45) s+=15; else if(r<50) s+=8;
   if(VolumeOK())     s+=10;
   if(VolatilityOK()) s+=5;
   if(RetestBear())   s+=10;
   return MathMin(100.0,s);
  }

int Bias()
  {
   if(g_bull >= g_bear + InpFlipMargin) return 1;
   if(g_bear >= g_bull + InpFlipMargin) return -1;
   // within margin: keep current side if any, else stronger side
   int held=NetSide();
   if(held!=0) return held;
   if(g_bull>g_bear) return 1;
   if(g_bear>g_bull) return -1;
   return 0;
  }

//+==================================================================+
//|  STRUCTURE / SMC HELPERS                                         |
//+==================================================================+
int SwingHighShift(int rank)
  {
   int L=InpSwingLookback, found=0;
   for(int k=L;k<=InpScanBars-L;k++)
     {
      double h=iHigh(_Symbol,InpTF,k); bool sw=true;
      for(int j=1;j<=L;j++)
         if(iHigh(_Symbol,InpTF,k-j)>=h||iHigh(_Symbol,InpTF,k+j)>=h){sw=false;break;}
      if(sw){ if(found==rank) return k; found++; }
     }
   return -1;
  }
int SwingLowShift(int rank)
  {
   int L=InpSwingLookback, found=0;
   for(int k=L;k<=InpScanBars-L;k++)
     {
      double lo=iLow(_Symbol,InpTF,k); bool sw=true;
      for(int j=1;j<=L;j++)
         if(iLow(_Symbol,InpTF,k-j)<=lo||iLow(_Symbol,InpTF,k+j)<=lo){sw=false;break;}
      if(sw){ if(found==rank) return k; found++; }
     }
   return -1;
  }

bool StructureUp()
  {
   int h0=SwingHighShift(0),h1=SwingHighShift(1),l0=SwingLowShift(0),l1=SwingLowShift(1);
   if(h0<0||h1<0||l0<0||l1<0) return false;
   return iHigh(_Symbol,InpTF,h0)>iHigh(_Symbol,InpTF,h1) &&
          iLow(_Symbol,InpTF,l0)>iLow(_Symbol,InpTF,l1);
  }
bool StructureDown()
  {
   int h0=SwingHighShift(0),h1=SwingHighShift(1),l0=SwingLowShift(0),l1=SwingLowShift(1);
   if(h0<0||h1<0||l0<0||l1<0) return false;
   return iHigh(_Symbol,InpTF,h0)<iHigh(_Symbol,InpTF,h1) &&
          iLow(_Symbol,InpTF,l0)<iLow(_Symbol,InpTF,l1);
  }

bool BosBullish(){ int s=SwingHighShift(0); return s>0 && iClose(_Symbol,InpTF,1)>iHigh(_Symbol,InpTF,s); }
bool BosBearish(){ int s=SwingLowShift(0);  return s>0 && iClose(_Symbol,InpTF,1)<iLow(_Symbol,InpTF,s); }
bool ChochBullish(){ return StructureDown() && BosBullish(); }
bool ChochBearish(){ return StructureUp()   && BosBearish(); }

bool RetestBull()
  {
   int s=SwingHighShift(0); if(s<1) return false;
   double lvl=iHigh(_Symbol,InpTF,s); double atr=CurrentATR();
   return iLow(_Symbol,InpTF,1)<=lvl+0.5*atr && iClose(_Symbol,InpTF,1)>lvl;
  }
bool RetestBear()
  {
   int s=SwingLowShift(0); if(s<1) return false;
   double lvl=iLow(_Symbol,InpTF,s); double atr=CurrentATR();
   return iHigh(_Symbol,InpTF,1)>=lvl-0.5*atr && iClose(_Symbol,InpTF,1)<lvl;
  }

bool VolumeOK()
  {
   long v[]; ArraySetAsSeries(v,true);
   if(CopyTickVolume(_Symbol,InpTF,0,22,v)<22) return false;
   double avg=0; for(int i=2;i<=21;i++) avg+=(double)v[i]; avg/=20.0;
   return ((double)v[1] >= InpVolMult*avg);
  }

//+==================================================================+
//|  POSITION / RISK HELPERS                                         |
//+==================================================================+
double EMA(int handle){ double b[1]; if(CopyBuffer(handle,0,1,1,b)<1) return 0.0; return b[0]; }
double RSIval(){ double b[1]; if(CopyBuffer(hRSI,0,1,1,b)<1) return 50.0; return b[0]; }
double CurrentATR(){ double b[1]; if(CopyBuffer(hATR,0,1,1,b)<1) return 0.0; return b[0]; }
bool   VolatilityOK(){ double a=CurrentATR(),p=SymbolInfoDouble(_Symbol,SYMBOL_BID); if(a<=0||p<=0) return false; double x=a/p; return (x>=0.0005 && x<=0.06); }
int    SpreadPoints(){ return (int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD); }
double SpreadPct(){ double a=SymbolInfoDouble(_Symbol,SYMBOL_ASK),b=SymbolInfoDouble(_Symbol,SYMBOL_BID); if(b<=0) return 0.0; return (a-b)/b*100.0; }
double MarginLevel(){ double m=AccountInfoDouble(ACCOUNT_MARGIN); if(m<=0.0) return 1e9; return AccountInfoDouble(ACCOUNT_MARGIN_LEVEL); }

bool PositionsExistAny(){ return NetSide()!=0; }

int NetSide()
  {
   double vbuy=0,vsell=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) vbuy+=PositionGetDouble(POSITION_VOLUME);
      else vsell+=PositionGetDouble(POSITION_VOLUME);
     }
   if(vbuy>vsell) return 1;
   if(vsell>vbuy) return -1;
   return 0;
  }

double BasketProfit()
  {
   double p=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t) &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic &&
         PositionGetString(POSITION_SYMBOL)==_Symbol)
         p+=PositionGetDouble(POSITION_PROFIT);
     }
   return p;
  }

int OpenCount()
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

double ExposurePct()
  {
   double eq=AccountInfoDouble(ACCOUNT_EQUITY); if(eq<=0) return 0.0;
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tv<=0||ts<=0) return 0.0;
   double riskMoney=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double vol=PositionGetDouble(POSITION_VOLUME);
      double dist=(sl>0.0)?MathAbs(open-sl):CurrentATR()*InpSLAtrMult;
      riskMoney+=(dist/ts)*tv*vol;
     }
   return riskMoney/eq*100.0;
  }

double CalcLot(double slDist,double riskPct)
  {
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney=eq*(riskPct/100.0);
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tv<=0||ts<=0||slDist<=0) return 0.0;
   double lossPerLot=(slDist/ts)*tv; if(lossPerLot<=0) return 0.0;
   double lot=riskMoney/lossPerLot;
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(step>0) lot=MathFloor(lot/step)*step;
   lot=MathMax(lot,vmin); lot=MathMin(lot,vmax);
   return NormalizeDouble(lot,2);
  }

void CloseSide(int side)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long type=PositionGetInteger(POSITION_TYPE);
      if((side>0 && type==POSITION_TYPE_BUY)||(side<0 && type==POSITION_TYPE_SELL))
         trade.PositionClose(t);
     }
   if(NetSide()==0) g_side=0;
  }

void CloseAll(){ CloseSide(1); CloseSide(-1); g_side=0; }

//+==================================================================+
//|  RISK GATES                                                      |
//+==================================================================+
bool CanTrade()
  {
   if(g_emergency){ g_status="emergency"; return false; }
   if(g_haltWeek){ g_status="weekly DD halt"; return false; }
   if(g_haltDay){ g_status="daily DD halt"; return false; }
   if(g_consec>=InpMaxConsecLoss){ g_status="loss-streak pause"; return false; }
   if(SpreadPct()>InpMaxSpreadPct){ g_status="spread too high"; return false; }
   return true;
  }

void UpdateRiskMarks()
  {
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq>g_peakEq) g_peakEq=eq;
   if(g_peakEq>0 && (g_peakEq-eq)/g_peakEq*100.0>=InpEmergencyDD) g_emergency=true;
   if(g_dayStartEq>0 && (g_dayStartEq-eq)/g_dayStartEq*100.0>=InpMaxDailyDD) g_haltDay=true;
   if(g_weekStartEq>0 && (g_weekStartEq-eq)/g_weekStartEq*100.0>=InpMaxWeeklyDD) g_haltWeek=true;
  }

void RollDayWeek()
  {
   datetime today=StartOfDay(TimeCurrent());
   if(today!=g_day){ g_day=today; g_dayStartEq=AccountInfoDouble(ACCOUNT_EQUITY); g_haltDay=false; }
   int wk=WeekIndex(TimeCurrent());
   if(wk!=g_week){ g_week=wk; g_weekStartEq=AccountInfoDouble(ACCOUNT_EQUITY); g_haltWeek=false; }
  }

datetime StartOfDay(datetime t){ MqlDateTime s; TimeToStruct(t,s); s.hour=0; s.min=0; s.sec=0; return StructToTime(s); }
int WeekIndex(datetime t){ MqlDateTime s; TimeToStruct(t,s); return s.year*54+(s.day_of_year/7); }

//+==================================================================+
//|  DASHBOARD                                                       |
//+==================================================================+
void UpdateDashboard()
  {
   int held=NetSide();
   string biasTxt=(held>0?"LONG":held<0?"SHORT":"FLAT");
   string struc=StructureUp()?"Uptrend (HH/HL)":StructureDown()?"Downtrend (LH/LL)":"Ranging";
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double ddDay=(g_dayStartEq>0)?(g_dayStartEq-eq)/g_dayStartEq*100.0:0.0;

   string s="";
   s+="================ LexiAdaptive ================\n";
   s+=StringFormat("Bullish Confidence : %.0f / 100\n", g_bull);
   s+=StringFormat("Bearish Confidence : %.0f / 100\n", g_bear);
   s+=StringFormat("Current Bias       : %s\n", biasTxt);
   s+=StringFormat("Market Structure   : %s\n", struc);
   s+=StringFormat("Open Trades        : %d\n", OpenCount());
   s+=StringFormat("Floating P/L       : %.2f %s\n", BasketProfit(), AccountInfoString(ACCOUNT_CURRENCY));
   s+=StringFormat("Risk Exposure      : %.2f%% / %.0f%%\n", ExposurePct(), InpMaxExposure);
   s+=StringFormat("Daily Drawdown     : %.2f%% / %.0f%%\n", ddDay, InpMaxDailyDD);
   s+=StringFormat("Consec. Losses     : %d / %d\n", g_consec, InpMaxConsecLoss);
   s+=StringFormat("Spread             : %.3f%% / %.3f%%\n", SpreadPct(), InpMaxSpreadPct);
   s+=StringFormat("Entry needs conf   : >= %.0f (margin %.0f)\n", InpEntryConfidence, InpFlipMargin);
   s+=StringFormat("EA Status          : %s\n", g_status);
   s+="=============================================";
   Comment(s);
  }
//+------------------------------------------------------------------+
