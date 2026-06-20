//+------------------------------------------------------------------+
//|                                                  LexiScalper.mq5  |
//|   High-frequency momentum scalper (EMA/RSI/ATR/Volume only)      |
//|                                                                  |
//|   BUY  : EMA20>EMA50, RSI>thr, bullish momentum candle, volume up |
//|   SELL : EMA20<EMA50, RSI<thr, bearish momentum candle, volume up |
//|   TP   : ATR x 0.2-0.3   SL : ATR x 0.4-0.6                       |
//|   Many small trades, fast re-entry, both directions, flips fast. |
//|   No BOS/CHoCH/FVG/liquidity. NOT martingale, NOT grid.          |
//|                                                                  |
//|   !! SCALPING IS SPREAD-SENSITIVE. If spread >= take-profit       |
//|      distance the EA refuses to trade (you'd lose the spread).    |
//|   TEST ON DEMO FIRST. High risk, no profit guaranteed.           |
//+------------------------------------------------------------------+
#property copyright "Lexi"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//--- Core -----------------------------------------------------------
input ENUM_TIMEFRAMES InpTF = PERIOD_M1;   // Working timeframe (M1 = fastest)
input int    InpEmaFast   = 20;
input int    InpEmaSlow   = 50;
input int    InpRSIPeriod = 14;
input double InpRSIBuy    = 55.0;    // RSI above this for BUY
input double InpRSISell   = 45.0;    // RSI below this for SELL
input int    InpATRPeriod = 14;
input double InpVolMult   = 1.1;     // Volume vs average to count as "above average"
input double InpBodyFrac  = 0.30;    // Momentum candle body >= this of the range

//--- Exits ----------------------------------------------------------
input double InpTPmult    = 0.25;    // Take profit = ATR x this (0.2-0.3)
input double InpSLmult    = 0.50;    // Stop loss   = ATR x this (0.4-0.6)

//--- Position / risk -----------------------------------------------
input double InpRiskPct   = 0.25;    // % risk per trade
input int    InpMaxPositions = 3;    // Max simultaneous (0 = unlimited)
input bool   InpFlipOpposite = true; // Close opposite trades on a flip
input double InpMaxDailyDD = 5.0;    // % daily drawdown -> stop for the day

//--- Failsafe -------------------------------------------------------
input double InpMaxSpreadPct = 0.05; // Skip if spread > this % of price
input double InpSpreadTPratio= 0.80; // Skip if spread >= this x TP distance

//--- General --------------------------------------------------------
input long   InpMagic     = 550125;
input int    InpSlippagePts = 50;
input bool   InpDashboard = true;

//--- Globals --------------------------------------------------------
CTrade   trade;
int      hEf=INVALID_HANDLE,hEs=INVALID_HANDLE,hRSI=INVALID_HANDLE,hATR=INVALID_HANDLE;
datetime g_lastBar=0,g_day=0;
double   g_dayStartEq=0;
bool     g_haltDay=false;
string   g_status="init";

//+------------------------------------------------------------------+
int OnInit()
  {
   hEf =iMA(_Symbol,InpTF,InpEmaFast,0,MODE_EMA,PRICE_CLOSE);
   hEs =iMA(_Symbol,InpTF,InpEmaSlow,0,MODE_EMA,PRICE_CLOSE);
   hRSI=iRSI(_Symbol,InpTF,InpRSIPeriod,PRICE_CLOSE);
   hATR=iATR(_Symbol,InpTF,InpATRPeriod);
   if(hEf==INVALID_HANDLE||hEs==INVALID_HANDLE||hRSI==INVALID_HANDLE||hATR==INVALID_HANDLE)
     { Print("ERROR: handles failed"); return(INIT_FAILED); }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);
   g_day=StartOfDay(TimeCurrent());
   g_dayStartEq=AccountInfoDouble(ACCOUNT_EQUITY);
   PrintFormat("LexiScalper on %s %s",_Symbol,EnumToString(InpTF));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(hEf!=INVALID_HANDLE) IndicatorRelease(hEf);
   if(hEs!=INVALID_HANDLE) IndicatorRelease(hEs);
   if(hRSI!=INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR!=INVALID_HANDLE) IndicatorRelease(hATR);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   RollDay();
   // one decision per finished bar (keeps it fast but not chaotic)
   datetime bt=iTime(_Symbol,InpTF,0);
   if(bt==g_lastBar){ if(InpDashboard) Dashboard(); return; }
   g_lastBar=bt;

   if(!CanTrade()){ if(InpDashboard) Dashboard(); return; }

   int sig=Signal();              // +1 buy, -1 sell, 0 none
   if(sig!=0)
     {
      int held=NetSide();
      if(InpFlipOpposite && held!=0 && held!=sig) CloseSide(held);
      if(InpMaxPositions==0 || CountMine()<InpMaxPositions)
         OpenTrade(sig);
     }
   else g_status="no signal";

   if(InpDashboard) Dashboard();
  }

//+==================================================================+
//|  SIGNAL                                                          |
//+==================================================================+
int Signal()
  {
   double ef=EMA(hEf),es=EMA(hEs),r=RSIval();
   bool volOK=VolumeOK();
   if(ef>es && r>InpRSIBuy && MomentumBull() && volOK){ g_status="BUY signal"; return 1; }
   if(ef<es && r<InpRSISell && MomentumBear() && volOK){ g_status="SELL signal"; return -1; }
   return 0;
  }

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

//+==================================================================+
//|  ORDER                                                           |
//+==================================================================+
void OpenTrade(int side)
  {
   double atr=CurrentATR(); if(atr<=0.0){ g_status="no ATR"; return; }
   double tpDist=atr*InpTPmult, slDist=atr*InpSLmult;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double spread=ask-bid;

   // Scalp must clear the spread, otherwise every "win" is a loss.
   if(spread>=InpSpreadTPratio*tpDist){ g_status="spread >= TP: skip"; return; }
   if(SpreadPct()>InpMaxSpreadPct){ g_status="spread too high"; return; }

   double lot=CalcLot(slDist); if(lot<=0.0){ g_status="lot=0"; return; }

   double price,sl,tp;
   if(side>0){ price=ask; sl=price-slDist; tp=price+tpDist; }
   else      { price=bid; sl=price+slDist; tp=price-tpDist; }
   sl=NormalizeDouble(sl,_Digits); tp=NormalizeDouble(tp,_Digits);

   bool ok=(side>0)?trade.Buy(lot,_Symbol,price,sl,tp,"LexiScalper")
                   :trade.Sell(lot,_Symbol,price,sl,tp,"LexiScalper");
   if(ok) g_status=(side>0?"opened BUY":"opened SELL");
   else   PrintFormat("order failed %d %s",trade.ResultRetcode(),trade.ResultRetcodeDescription());
  }

//+==================================================================+
//|  HELPERS                                                         |
//+==================================================================+
double EMA(int h){ double b[1]; if(CopyBuffer(h,0,1,1,b)<1) return 0.0; return b[0]; }
double RSIval(){ double b[1]; if(CopyBuffer(hRSI,0,1,1,b)<1) return 50.0; return b[0]; }
double CurrentATR(){ double b[1]; if(CopyBuffer(hATR,0,1,1,b)<1) return 0.0; return b[0]; }
double SpreadPct(){ double a=SymbolInfoDouble(_Symbol,SYMBOL_ASK),b=SymbolInfoDouble(_Symbol,SYMBOL_BID); if(b<=0) return 0.0; return (a-b)/b*100.0; }

int NetSide()
  {
   double vb=0,vs=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) vb+=PositionGetDouble(POSITION_VOLUME); else vs+=PositionGetDouble(POSITION_VOLUME);
     }
   if(vb>vs) return 1; if(vs>vb) return -1; return 0;
  }

int CountMine()
  {
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t)&&PositionGetInteger(POSITION_MAGIC)==InpMagic&&PositionGetString(POSITION_SYMBOL)==_Symbol) c++;
     }
   return c;
  }

double BasketProfit()
  {
   double p=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t)&&PositionGetInteger(POSITION_MAGIC)==InpMagic&&PositionGetString(POSITION_SYMBOL)==_Symbol) p+=PositionGetDouble(POSITION_PROFIT);
     }
   return p;
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
  }

double CalcLot(double slDist)
  {
   double eq=AccountInfoDouble(ACCOUNT_EQUITY),riskMoney=eq*(InpRiskPct/100.0);
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE),ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tv<=0||ts<=0||slDist<=0) return 0.0;
   double lossPerLot=(slDist/ts)*tv; if(lossPerLot<=0) return 0.0;
   double lot=riskMoney/lossPerLot;
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(step>0) lot=MathFloor(lot/step)*step;
   lot=MathMax(lot,vmin); lot=MathMin(lot,vmax);
   return NormalizeDouble(lot,2);
  }

//+==================================================================+
//|  RISK / TIME                                                     |
//+==================================================================+
bool CanTrade()
  {
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_dayStartEq>0 && (g_dayStartEq-eq)/g_dayStartEq*100.0>=InpMaxDailyDD) g_haltDay=true;
   if(g_haltDay){ g_status="daily DD halt"; return false; }
   return true;
  }

void RollDay()
  {
   datetime d=StartOfDay(TimeCurrent());
   if(d!=g_day){ g_day=d; g_dayStartEq=AccountInfoDouble(ACCOUNT_EQUITY); g_haltDay=false; }
  }

datetime StartOfDay(datetime t){ MqlDateTime s; TimeToStruct(t,s); s.hour=0; s.min=0; s.sec=0; return StructToTime(s); }

//+==================================================================+
//|  DASHBOARD                                                       |
//+==================================================================+
void Dashboard()
  {
   double atr=CurrentATR(),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double tpDist=atr*InpTPmult, spread=ask-bid;
   string spreadWarn=(spread>=InpSpreadTPratio*tpDist)?"  <-- TOO WIDE FOR SCALPING!":"";
   string s="";
   s+="=============== LexiScalper ===============\n";
   s+=StringFormat("EMA20 %.2f  EMA50 %.2f  RSI %.1f\n",EMA(hEf),EMA(hEs),RSIval());
   s+=StringFormat("ATR %.2f   TP=%.2f  SL=%.2f\n",atr,tpDist,atr*InpSLmult);
   s+=StringFormat("Spread %.2f vs TP %.2f%s\n",spread,tpDist,spreadWarn);
   s+=StringFormat("Open Trades %d/%d   Floating %.2f %s\n",CountMine(),InpMaxPositions,BasketProfit(),AccountInfoString(ACCOUNT_CURRENCY));
   s+=StringFormat("Status: %s\n",g_status);
   s+="==========================================";
   Comment(s);
  }
//+------------------------------------------------------------------+
