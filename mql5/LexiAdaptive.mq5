//+------------------------------------------------------------------+
//|                                                 LexiAdaptive.mq5  |
//|   Adaptive opportunity-hunter EA for BTCUSD (M5)                 |
//|                                                                  |
//|   Dual confidence (Bull/Bear, 0-100) from EMA/RSI/Volume/ATR/    |
//|   momentum + market structure. BOS/CHoCH are only small boosters.|
//|   Enters small early, scales bigger as the trade proves correct. |
//|   NEVER averages down, NEVER adds to losers. Cuts losers fast,   |
//|   lets winners run, flips bias instantly.                       |
//|                                                                  |
//|   Risk: 0.25%/entry, 5% exposure, 5% daily, 10% weekly,         |
//|   15% emergency, pause after 5 consecutive losing deals.        |
//|   TEST ON DEMO FIRST. High risk, no profit guaranteed.          |
//+------------------------------------------------------------------+
#property copyright "Lexi"
#property version   "2.00"
#property strict

#include <Trade/Trade.mqh>

//--- Timeframe / EMAs ----------------------------------------------
input ENUM_TIMEFRAMES InpTF = PERIOD_M5;   // Working timeframe
input int    InpEma1 = 20;
input int    InpEma2 = 50;
input int    InpEma3 = 200;

//--- Indicators -----------------------------------------------------
input int    InpRSIPeriod    = 14;
input int    InpATRPeriod    = 14;
input int    InpSwingLookback= 3;
input int    InpScanBars     = 80;
input double InpVolMult      = 1.1;   // Volume vs average to count as "above average"
input double InpBodyFrac     = 0.40;  // Momentum candle: body must be >= this of range

//--- Confidence thresholds -----------------------------------------
input double InpOpenConf  = 60.0;   // Open first (exploratory) entry at/above this
input double InpAddConf   = 75.0;   // Allow adds at/above this
input double InpAddStep   = 5.0;    // Confidence must rise this much to add again
input double InpBiasMargin= 15.0;   // Bull/Bear gap to set a directional bias
input double InpExitConf  = 45.0;   // Held side below this -> exit it

//--- Position building / risk --------------------------------------
input double InpBaseRiskPct  = 0.25; // % risk per entry (scaled up by confidence)
input double InpMaxRiskMult   = 2.0;
input double InpMaxExposure   = 5.0; // % max total open risk
input double InpSLAtrMult     = 2.0;
input double InpTrailAtrMult  = 1.5;

//--- Quick profit (optional) ---------------------------------------
input bool   InpQuickClose       = false; // Bank a position at a small profit (off = let winners run)
input double InpQuickProfitMoney = 1.0;

//--- Drawdown / failsafe -------------------------------------------
input double InpMaxDailyDD    = 5.0;
input double InpMaxWeeklyDD   = 10.0;
input double InpEmergencyDD   = 15.0;
input int    InpMaxConsecLoss = 5;
input double InpMaxSpreadPct  = 0.06;  // % of price
input double InpMinMarginLevel= 200.0;

//--- General --------------------------------------------------------
input long   InpMagic        = 990125;
input int    InpSlippagePts  = 50;
input bool   InpDashboard    = true;

//--- Globals --------------------------------------------------------
CTrade   trade;
int      hE1=INVALID_HANDLE,hE2=INVALID_HANDLE,hE3=INVALID_HANDLE,hRSI=INVALID_HANDLE,hATR=INVALID_HANDLE;
datetime g_day=0; int g_week=-1;
double   g_dayStartEq=0,g_weekStartEq=0,g_peakEq=0;
int      g_consec=0;
bool     g_emergency=false,g_haltDay=false,g_haltWeek=false;
int      g_side=0;
double   g_lastAddConf=0.0,g_bull=0.0,g_bear=0.0;
string   g_status="init";

//+------------------------------------------------------------------+
int OnInit()
  {
   hE1=iMA(_Symbol,InpTF,InpEma1,0,MODE_EMA,PRICE_CLOSE);
   hE2=iMA(_Symbol,InpTF,InpEma2,0,MODE_EMA,PRICE_CLOSE);
   hE3=iMA(_Symbol,InpTF,InpEma3,0,MODE_EMA,PRICE_CLOSE);
   hRSI=iRSI(_Symbol,InpTF,InpRSIPeriod,PRICE_CLOSE);
   hATR=iATR(_Symbol,InpTF,InpATRPeriod);
   if(hE1==INVALID_HANDLE||hE2==INVALID_HANDLE||hE3==INVALID_HANDLE||hRSI==INVALID_HANDLE||hATR==INVALID_HANDLE)
     { Print("ERROR: handles failed"); return(INIT_FAILED); }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   g_peakEq=eq; g_dayStartEq=eq; g_weekStartEq=eq;
   g_day=StartOfDay(TimeCurrent()); g_week=WeekIndex(TimeCurrent());
   PrintFormat("LexiAdaptive v2 on %s %s",_Symbol,EnumToString(InpTF));
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

void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &req,const MqlTradeResult &res)
  {
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   ulong d=trans.deal;
   if(!HistoryDealSelect(d)) return;
   if(HistoryDealGetInteger(d,DEAL_MAGIC)!=InpMagic) return;
   if(HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol) return;
   if(HistoryDealGetInteger(d,DEAL_ENTRY)!=DEAL_ENTRY_OUT) return;
   double pnl=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_SWAP)+HistoryDealGetDouble(d,DEAL_COMMISSION);
   if(pnl<0.0) g_consec++; else if(pnl>0.0) g_consec=0;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)){ g_status="no connection"; return; }
   RollDayWeek();
   UpdateRiskMarks();
   if(g_emergency){ CloseAll(); g_status="EMERGENCY halt"; if(InpDashboard) UpdateDashboard(); return; }

   g_bull=BullConfidence();
   g_bear=BearConfidence();
   int bias=Bias();

   if(InpQuickClose) QuickCloseProfits();
   ManageExits();

   if(CanTrade()) EngineStep(bias);

   if(InpDashboard) UpdateDashboard();
  }

//+==================================================================+
//|  ENGINE: explore early, scale into winners, flip on reversal     |
//+==================================================================+
void EngineStep(int bias)
  {
   double conf=(bias>0)?g_bull:(bias<0?g_bear:0.0);
   int held=NetSide();

   // Bias reversal: opposite side now favoured -> drop the held side.
   if(held!=0 && bias!=0 && bias!=held)
     { CloseSide(held); g_side=0; held=0; }

   if(bias==0 || conf<InpOpenConf){ g_status=(held!=0?"managing":"flat/waiting"); return; }

   // First exploratory entry.
   if(held==0)
     {
      if(OpenEntry(bias,conf)){ g_side=bias; g_lastAddConf=conf; g_status="opened (explore)"; }
      return;
     }

   // Scale into a WINNER only.
   if(held==bias)
     {
      bool rising   = conf>=InpAddConf && conf>=g_lastAddConf+InpAddStep;
      bool inProfit = BasketProfit()>0.0;
      bool momentum = (bias>0)?MomentumBull():MomentumBear();
      bool room     = ExposurePct()<InpMaxExposure;
      if(rising && inProfit && momentum && room)
        {
         if(OpenEntry(bias,conf)){ g_lastAddConf=conf; g_status="added (scaling)"; }
        }
      else g_status="holding winner";
     }
  }

bool OpenEntry(int side,double conf)
  {
   if(SpreadPct()>InpMaxSpreadPct) return false;
   if(MarginLevel()<InpMinMarginLevel && PositionsExistAny()) return false;
   double atr=CurrentATR(); if(atr<=0.0) return false;
   double price=(side>0)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double slDist=atr*InpSLAtrMult;
   double sl=(side>0)?price-slDist:price+slDist;
   double mult=MathMin(InpMaxRiskMult,MathMax(1.0,conf/InpOpenConf));
   double riskPct=InpBaseRiskPct*mult;
   if(ExposurePct()+riskPct>InpMaxExposure) riskPct=InpMaxExposure-ExposurePct();
   if(riskPct<=0.01) return false;
   double lot=CalcLot(slDist,riskPct); if(lot<=0.0) return false;
   bool ok=(side>0)?trade.Buy(lot,_Symbol,price,sl,0.0,"LexiAdaptive")
                   :trade.Sell(lot,_Symbol,price,sl,0.0,"LexiAdaptive");
   if(!ok) PrintFormat("entry failed %d %s",trade.ResultRetcode(),trade.ResultRetcodeDescription());
   return ok;
  }

//+==================================================================+
//|  EXITS                                                           |
//+==================================================================+
void QuickCloseProfits()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetDouble(POSITION_PROFIT)>=InpQuickProfitMoney) trade.PositionClose(t);
     }
  }

void ManageExits()
  {
   double atr=CurrentATR(); if(atr<=0.0) return;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long type=PositionGetInteger(POSITION_TYPE);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP);
      if(type==POSITION_TYPE_BUY)
        {
         double n=sl;
         if(bid-entry>atr) n=MathMax(n,entry);
         double tr=bid-atr*InpTrailAtrMult; if(tr>n) n=tr;
         if(n>sl && n<bid) trade.PositionModify(t,NormalizeDouble(n,_Digits),tp);
        }
      else if(type==POSITION_TYPE_SELL)
        {
         double n=sl;
         if(entry-ask>atr) n=(sl==0.0)?entry:MathMin(n,entry);
         double tr=ask+atr*InpTrailAtrMult; if(sl==0.0||tr<n) n=tr;
         if((sl==0.0||n<sl) && n>ask) trade.PositionModify(t,NormalizeDouble(n,_Digits),tp);
        }
     }
   int held=NetSide();
   if(held>0 && (g_bull<InpExitConf || g_bear>g_bull+InpBiasMargin)) CloseSide(1);
   if(held<0 && (g_bear<InpExitConf || g_bull>g_bear+InpBiasMargin)) CloseSide(-1);
  }

//+==================================================================+
//|  DUAL CONFIDENCE (exact scoring + small BOS/CHoCH boosters)      |
//+==================================================================+
double BullConfidence()
  {
   double e1=EMA(hE1),e2=EMA(hE2),e3=EMA(hE3),r=RSIval(),s=0.0;
   if(e1>e2) s+=15;
   if(e2>e3) s+=15;
   if(HigherHigh()) s+=10;
   if(HigherLow())  s+=10;
   if(VolumeOK())   s+=15;
   if(r>55)         s+=10;
   if(AtrExpanding())s+=10;
   if(MomentumBull())s+=15;
   if(BosBullish())  s+=5;   // booster
   if(ChochBullish())s+=5;   // booster
   return MathMin(100.0,s);
  }

double BearConfidence()
  {
   double e1=EMA(hE1),e2=EMA(hE2),e3=EMA(hE3),r=RSIval(),s=0.0;
   if(e1<e2) s+=15;
   if(e2<e3) s+=15;
   if(LowerHigh()) s+=10;
   if(LowerLow())  s+=10;
   if(VolumeOK())  s+=15;
   if(r<45)        s+=10;
   if(AtrExpanding())s+=10;
   if(MomentumBear())s+=15;
   if(BosBearish())  s+=5;
   if(ChochBearish())s+=5;
   return MathMin(100.0,s);
  }

int Bias()
  {
   if(g_bull-g_bear>InpBiasMargin) return 1;
   if(g_bear-g_bull>InpBiasMargin) return -1;
   return 0;   // FLAT only when nearly equal
  }

//+==================================================================+
//|  MARKET STRUCTURE / CANDLE / ATR HELPERS                         |
//+==================================================================+
int SwingHighShift(int rank)
  {
   int L=InpSwingLookback,found=0;
   for(int k=L;k<=InpScanBars-L;k++)
     {
      double h=iHigh(_Symbol,InpTF,k); bool sw=true;
      for(int j=1;j<=L;j++) if(iHigh(_Symbol,InpTF,k-j)>=h||iHigh(_Symbol,InpTF,k+j)>=h){sw=false;break;}
      if(sw){ if(found==rank) return k; found++; }
     }
   return -1;
  }
int SwingLowShift(int rank)
  {
   int L=InpSwingLookback,found=0;
   for(int k=L;k<=InpScanBars-L;k++)
     {
      double lo=iLow(_Symbol,InpTF,k); bool sw=true;
      for(int j=1;j<=L;j++) if(iLow(_Symbol,InpTF,k-j)<=lo||iLow(_Symbol,InpTF,k+j)<=lo){sw=false;break;}
      if(sw){ if(found==rank) return k; found++; }
     }
   return -1;
  }
bool HigherHigh(){ int a=SwingHighShift(0),b=SwingHighShift(1); return a>=0&&b>=0&&iHigh(_Symbol,InpTF,a)>iHigh(_Symbol,InpTF,b); }
bool HigherLow(){  int a=SwingLowShift(0), b=SwingLowShift(1);  return a>=0&&b>=0&&iLow(_Symbol,InpTF,a)>iLow(_Symbol,InpTF,b); }
bool LowerHigh(){  int a=SwingHighShift(0),b=SwingHighShift(1); return a>=0&&b>=0&&iHigh(_Symbol,InpTF,a)<iHigh(_Symbol,InpTF,b); }
bool LowerLow(){   int a=SwingLowShift(0), b=SwingLowShift(1);  return a>=0&&b>=0&&iLow(_Symbol,InpTF,a)<iLow(_Symbol,InpTF,b); }
bool BosBullish(){ int s=SwingHighShift(0); return s>0 && iClose(_Symbol,InpTF,1)>iHigh(_Symbol,InpTF,s); }
bool BosBearish(){ int s=SwingLowShift(0);  return s>0 && iClose(_Symbol,InpTF,1)<iLow(_Symbol,InpTF,s); }
bool ChochBullish(){ return LowerHigh() && LowerLow() && BosBullish(); }
bool ChochBearish(){ return HigherHigh() && HigherLow() && BosBearish(); }

bool MomentumBull()
  {
   double o=iOpen(_Symbol,InpTF,1),c=iClose(_Symbol,InpTF,1),h=iHigh(_Symbol,InpTF,1),l=iLow(_Symbol,InpTF,1);
   double rng=h-l; return rng>0 && c>o && (c-o)>=InpBodyFrac*rng;
  }
bool MomentumBear()
  {
   double o=iOpen(_Symbol,InpTF,1),c=iClose(_Symbol,InpTF,1),h=iHigh(_Symbol,InpTF,1),l=iLow(_Symbol,InpTF,1);
   double rng=h-l; return rng>0 && c<o && (o-c)>=InpBodyFrac*rng;
  }

bool VolumeOK()
  {
   long v[]; ArraySetAsSeries(v,true);
   if(CopyTickVolume(_Symbol,InpTF,0,22,v)<22) return false;
   double avg=0; for(int i=2;i<=21;i++) avg+=(double)v[i]; avg/=20.0;
   return ((double)v[1]>=InpVolMult*avg);
  }

bool AtrExpanding()
  {
   double a[]; ArraySetAsSeries(a,true);
   if(CopyBuffer(hATR,0,0,25,a)<25) return false;
   double avg=0; for(int i=1;i<=20;i++) avg+=a[i]; avg/=20.0;
   return a[1]>avg;
  }

//+==================================================================+
//|  POSITION / RISK HELPERS                                         |
//+==================================================================+
double EMA(int handle){ double b[1]; if(CopyBuffer(handle,0,1,1,b)<1) return 0.0; return b[0]; }
double RSIval(){ double b[1]; if(CopyBuffer(hRSI,0,1,1,b)<1) return 50.0; return b[0]; }
double CurrentATR(){ double b[1]; if(CopyBuffer(hATR,0,1,1,b)<1) return 0.0; return b[0]; }
double SpreadPct(){ double a=SymbolInfoDouble(_Symbol,SYMBOL_ASK),b=SymbolInfoDouble(_Symbol,SYMBOL_BID); if(b<=0) return 0.0; return (a-b)/b*100.0; }
double MarginLevel(){ double m=AccountInfoDouble(ACCOUNT_MARGIN); if(m<=0.0) return 1e9; return AccountInfoDouble(ACCOUNT_MARGIN_LEVEL); }
bool   PositionsExistAny(){ return NetSide()!=0; }

int NetSide()
  {
   double vb=0,vs=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) vb+=PositionGetDouble(POSITION_VOLUME);
      else vs+=PositionGetDouble(POSITION_VOLUME);
     }
   if(vb>vs) return 1; if(vs>vb) return -1; return 0;
  }

double BasketProfit()
  {
   double p=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t)&&PositionGetInteger(POSITION_MAGIC)==InpMagic&&PositionGetString(POSITION_SYMBOL)==_Symbol)
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
      if(PositionSelectByTicket(t)&&PositionGetInteger(POSITION_MAGIC)==InpMagic&&PositionGetString(POSITION_SYMBOL)==_Symbol) c++;
     }
   return c;
  }

double ExposurePct()
  {
   double eq=AccountInfoDouble(ACCOUNT_EQUITY); if(eq<=0) return 0.0;
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE),ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tv<=0||ts<=0) return 0.0;
   double rm=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      double open=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL),vol=PositionGetDouble(POSITION_VOLUME);
      double dist=(sl>0.0)?MathAbs(open-sl):CurrentATR()*InpSLAtrMult;
      rm+=(dist/ts)*tv*vol;
     }
   return rm/eq*100.0;
  }

double CalcLot(double slDist,double riskPct)
  {
   double eq=AccountInfoDouble(ACCOUNT_EQUITY),riskMoney=eq*(riskPct/100.0);
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE),ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tv<=0||ts<=0||slDist<=0) return 0.0;
   double lossPerLot=(slDist/ts)*tv; if(lossPerLot<=0) return 0.0;
   double lot=riskMoney/lossPerLot;
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
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
      if((side>0&&type==POSITION_TYPE_BUY)||(side<0&&type==POSITION_TYPE_SELL)) trade.PositionClose(t);
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
   string struc=(HigherHigh()&&HigherLow())?"Uptrend (HH/HL)":(LowerHigh()&&LowerLow())?"Downtrend (LH/LL)":"Mixed/Range";
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double ddDay=(g_dayStartEq>0)?(g_dayStartEq-eq)/g_dayStartEq*100.0:0.0;
   string s="";
   s+="============== LexiAdaptive v2 ==============\n";
   s+=StringFormat("Bullish Confidence : %.0f / 100\n",g_bull);
   s+=StringFormat("Bearish Confidence : %.0f / 100\n",g_bear);
   s+=StringFormat("Current Bias       : %s\n",biasTxt);
   s+=StringFormat("Market Structure   : %s\n",struc);
   s+=StringFormat("Open Trades        : %d\n",OpenCount());
   s+=StringFormat("Floating P/L       : %.2f %s\n",BasketProfit(),AccountInfoString(ACCOUNT_CURRENCY));
   s+=StringFormat("Risk Exposure      : %.2f%% / %.0f%%\n",ExposurePct(),InpMaxExposure);
   s+=StringFormat("Daily Drawdown     : %.2f%% / %.0f%%\n",ddDay,InpMaxDailyDD);
   s+=StringFormat("Consec. Losses     : %d / %d\n",g_consec,InpMaxConsecLoss);
   s+=StringFormat("Spread             : %.3f%% / %.3f%%\n",SpreadPct(),InpMaxSpreadPct);
   s+=StringFormat("Open>=%.0f  Add>=%.0f  BiasGap>=%.0f\n",InpOpenConf,InpAddConf,InpBiasMargin);
   s+=StringFormat("EA Status          : %s\n",g_status);
   s+="=============================================";
   Comment(s);
  }
//+------------------------------------------------------------------+
