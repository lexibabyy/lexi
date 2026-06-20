//+------------------------------------------------------------------+
//|                                              LexiGoldScalper.mq5  |
//|   Professional XAUUSD M1 momentum scalper                        |
//|                                                                  |
//|   Features: direction mode (buy/sell/both), weekly schedule +    |
//|   session window, news filter (MT5 calendar), holiday filter,    |
//|   daily profit target + max drawdown, risk-based sizing, spread  |
//|   guard, and a real-time trading panel.                          |
//|                                                                  |
//|   Signal: EMA20/50 + RSI + momentum candle + volume.            |
//|   NOT martingale, NOT a defending grid (kept clean & safe).      |
//|   TEST ON DEMO FIRST. High risk, no profit guaranteed.          |
//+------------------------------------------------------------------+
#property copyright "Lexi"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

enum ENUM_DIR { DIR_BOTH=0, DIR_BUY_ONLY=1, DIR_SELL_ONLY=2 };

//--- Core -----------------------------------------------------------
input ENUM_TIMEFRAMES InpTF = PERIOD_M1;
input ENUM_DIR InpDirection = DIR_BOTH;     // Allowed trade direction
input bool   InpUseHTFTrend = false;        // Confirm with higher timeframe (filters retracements)
input ENUM_TIMEFRAMES InpHTF = PERIOD_M15;  // Higher timeframe for confirmation
input int    InpEmaFast   = 20;
input int    InpEmaSlow   = 50;
input int    InpRSIPeriod = 14;
input double InpRSIBuy    = 55.0;
input double InpRSISell   = 45.0;
input int    InpATRPeriod = 14;
input double InpVolMult   = 1.1;
input double InpBodyFrac  = 0.30;

//--- Exits ----------------------------------------------------------
input double InpTPmult    = 0.8;    // Auto Take profit = ATR x this
input double InpSLmult    = 1.2;    // Auto Stop loss   = ATR x this
input bool   InpUseFixedTP    = false; // Use fixed TP in points (else automated ATR)
input int    InpFixedTPpoints = 200;   // Fixed take-profit (points)
input bool   InpUseFixedSL    = false; // Use fixed SL in points (else automated ATR)
input int    InpFixedSLpoints = 400;   // Fixed stop-loss (points)
input bool   InpUseTrailing   = true;  // Built-in trailing stop
input int    InpTrailStartPts = 150;   // Start trailing after this profit (points)
input int    InpTrailDistPts  = 120;   // Keep stop this far behind price (points)
input int    InpTrailStepPts  = 20;    // Minimum move to update the stop (points)
input bool   InpUseEarlyBE    = true;  // Move SL above entry on a TINY profit (fewer SL hits)
input int    InpBETriggerPts  = 30;    // Trigger breakeven after this profit (points)
input int    InpBELockPts     = 5;     // Lock SL this many points above entry

//--- Position / risk -----------------------------------------------
input double InpRiskPct      = 0.25;
input bool   InpUseFixedLot  = false;  // Use a fixed lot instead of % risk sizing
input double InpFixedLot      = 0.01;  // Fixed lot size (you control it)
input int    InpMaxPositions = 3;
input bool   InpFlipOpposite = true;

//--- Daily limits ---------------------------------------------------
input double InpMaxDailyDD     = 5.0;   // % daily drawdown -> stop for day
input double InpDailyProfitTgt = 0.0;   // Stop for day after this profit (acct ccy; 0=off)
input double InpDailyTargetPct = 0.0;   // OR stop after this % of day-start equity (0=off; auto-scales)

//--- Spread filter --------------------------------------------------
input double InpMaxSpreadPct = 0.05;
input double InpSpreadTPratio= 0.80;    // Skip if spread >= this x TP distance

//--- Trading schedule (server time) --------------------------------
input bool   InpUseSession  = true;
input int    InpSessionStart= 7;        // session start hour
input int    InpSessionEnd  = 21;       // session end hour
input bool   InpTradeMon=true, InpTradeTue=true, InpTradeWed=true;
input bool   InpTradeThu=true, InpTradeFri=true, InpTradeSat=false, InpTradeSun=false;

//--- News filter (uses MT5 economic calendar) ----------------------
input bool   InpUseNews     = true;
input int    InpNewsImportance = 3;     // 1=low 2=moderate 3=high
input int    InpNewsBeforeMin= 15;      // block this many minutes before
input int    InpNewsAfterMin = 15;      // and after a qualifying event
input string InpNewsCurrency = "USD";   // currency to watch (gold = USD)

//--- Holiday filter -------------------------------------------------
input string InpHolidayDates = "";      // "2026.12.25,2026.01.01" -> skip these days

//--- General --------------------------------------------------------
input long   InpMagic     = 560125;
input int    InpSlippagePts = 30;
input bool   InpDashboard = true;

//--- Globals --------------------------------------------------------
CTrade   trade;
int      hEf=INVALID_HANDLE,hEs=INVALID_HANDLE,hRSI=INVALID_HANDLE,hATR=INVALID_HANDLE;
int      hHTFf=INVALID_HANDLE,hHTFs=INVALID_HANDLE;
datetime g_lastBar=0,g_day=0;
double   g_dayStartEq=0;
int      g_tradesToday=0;
bool     g_haltDay=false;
string   g_status="init",g_newsTxt="";

//+------------------------------------------------------------------+
int OnInit()
  {
   hEf =iMA(_Symbol,InpTF,InpEmaFast,0,MODE_EMA,PRICE_CLOSE);
   hEs =iMA(_Symbol,InpTF,InpEmaSlow,0,MODE_EMA,PRICE_CLOSE);
   hRSI=iRSI(_Symbol,InpTF,InpRSIPeriod,PRICE_CLOSE);
   hATR=iATR(_Symbol,InpTF,InpATRPeriod);
   hHTFf=iMA(_Symbol,InpHTF,InpEmaFast,0,MODE_EMA,PRICE_CLOSE);
   hHTFs=iMA(_Symbol,InpHTF,InpEmaSlow,0,MODE_EMA,PRICE_CLOSE);
   if(hEf==INVALID_HANDLE||hEs==INVALID_HANDLE||hRSI==INVALID_HANDLE||hATR==INVALID_HANDLE||hHTFf==INVALID_HANDLE||hHTFs==INVALID_HANDLE)
     { Print("ERROR: handles failed"); return(INIT_FAILED); }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);
   g_day=StartOfDay(TimeCurrent());
   g_dayStartEq=AccountInfoDouble(ACCOUNT_EQUITY);
   PrintFormat("LexiGoldScalper on %s %s",_Symbol,EnumToString(InpTF));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(hEf!=INVALID_HANDLE) IndicatorRelease(hEf);
   if(hEs!=INVALID_HANDLE) IndicatorRelease(hEs);
   if(hRSI!=INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR!=INVALID_HANDLE) IndicatorRelease(hATR);
   if(hHTFf!=INVALID_HANDLE) IndicatorRelease(hHTFf);
   if(hHTFs!=INVALID_HANDLE) IndicatorRelease(hHTFs);
   Comment("");
  }

int HTFTrend()
  {
   double f[1],s[1];
   if(CopyBuffer(hHTFf,0,1,1,f)<1) return 0;
   if(CopyBuffer(hHTFs,0,1,1,s)<1) return 0;
   if(f[0]>s[0]) return 1;
   if(f[0]<s[0]) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   RollDay();
   if(InpUseTrailing||InpUseEarlyBE) ManageTrailing();   // breakeven + trail every tick
   datetime bt=iTime(_Symbol,InpTF,0);
   if(bt==g_lastBar){ if(InpDashboard) Dashboard(); return; }
   g_lastBar=bt;

   if(CanTrade())
     {
      int sig=Signal();
      if(sig>0 && InpDirection==DIR_SELL_ONLY) sig=0;
      if(sig<0 && InpDirection==DIR_BUY_ONLY)  sig=0;
      if(sig!=0)
        {
         int held=NetSide();
         if(InpFlipOpposite && held!=0 && held!=sig) CloseSide(held);
         if(InpMaxPositions==0 || CountMine()<InpMaxPositions) OpenTrade(sig);
        }
      else if(g_status=="" || g_status=="init") g_status="no signal";
     }
   if(InpDashboard) Dashboard();
  }

//+==================================================================+
//|  SIGNAL                                                          |
//+==================================================================+
int Signal()
  {
   double ef=EMA(hEf),es=EMA(hEs),r=RSIval();
   bool volOK=VolumeOK();
   int htf=InpUseHTFTrend?HTFTrend():0;
   if(ef>es && r>InpRSIBuy && MomentumBull() && volOK)
     {
      if(InpUseHTFTrend && htf<1){ g_status="BUY blocked: HTF not up (retracement?)"; return 0; }
      g_status="BUY signal"; return 1;
     }
   if(ef<es && r<InpRSISell && MomentumBear() && volOK)
     {
      if(InpUseHTFTrend && htf>-1){ g_status="SELL blocked: HTF not down (retracement?)"; return 0; }
      g_status="SELL signal"; return -1;
     }
   g_status="no signal"; return 0;
  }
bool MomentumBull(){ double o=iOpen(_Symbol,InpTF,1),c=iClose(_Symbol,InpTF,1),h=iHigh(_Symbol,InpTF,1),l=iLow(_Symbol,InpTF,1); double rng=h-l; return rng>0&&c>o&&(c-o)>=InpBodyFrac*rng; }
bool MomentumBear(){ double o=iOpen(_Symbol,InpTF,1),c=iClose(_Symbol,InpTF,1),h=iHigh(_Symbol,InpTF,1),l=iLow(_Symbol,InpTF,1); double rng=h-l; return rng>0&&c<o&&(o-c)>=InpBodyFrac*rng; }
bool VolumeOK(){ long v[]; ArraySetAsSeries(v,true); if(CopyTickVolume(_Symbol,InpTF,0,22,v)<22) return false; double avg=0; for(int i=2;i<=21;i++) avg+=(double)v[i]; avg/=20.0; return ((double)v[1]>=InpVolMult*avg); }

//+==================================================================+
//|  ORDER                                                           |
//+==================================================================+
void OpenTrade(int side)
  {
   double atr=CurrentATR(); if(atr<=0.0){ g_status="no ATR"; return; }
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double tpDist=InpUseFixedTP?InpFixedTPpoints*point:atr*InpTPmult;
   double slDist=InpUseFixedSL?InpFixedSLpoints*point:atr*InpSLmult;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double spread=ask-bid;
   if(spread>=InpSpreadTPratio*tpDist){ g_status="spread >= TP: skip"; return; }
   if(SpreadPct()>InpMaxSpreadPct){ g_status="spread too high"; return; }
   double lot=CalcLot(slDist); if(lot<=0.0){ g_status="lot=0"; return; }
   double price,sl,tp;
   if(side>0){ price=ask; sl=price-slDist; tp=price+tpDist; }
   else      { price=bid; sl=price+slDist; tp=price-tpDist; }
   sl=NormalizeDouble(sl,_Digits); tp=NormalizeDouble(tp,_Digits);
   bool ok=(side>0)?trade.Buy(lot,_Symbol,price,sl,tp,"LexiGoldScalper")
                   :trade.Sell(lot,_Symbol,price,sl,tp,"LexiGoldScalper");
   if(ok){ g_tradesToday++; g_status=(side>0?"opened BUY":"opened SELL"); }
   else PrintFormat("order failed %d %s",trade.ResultRetcode(),trade.ResultRetcodeDescription());
  }

//+==================================================================+
//|  TRAILING STOP                                                   |
//+==================================================================+
void ManageTrailing()
  {
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double start=InpTrailStartPts*point,dist=InpTrailDistPts*point,step=InpTrailStepPts*point;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long type=PositionGetInteger(POSITION_TYPE);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP);
      double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
      if(type==POSITION_TYPE_BUY)
        {
         double n=sl;
         // Early breakeven: tiny profit -> lock SL just above entry.
         if(InpUseEarlyBE && (bid-entry)>=InpBETriggerPts*point)
            n=MathMax(n,entry+InpBELockPts*point);
         // Trailing for larger moves.
         if(InpUseTrailing && (bid-entry)>=start)
            n=MathMax(n,bid-dist);
         n=NormalizeDouble(n,_Digits);
         if(n>sl && n<bid) trade.PositionModify(t,n,tp);
        }
      else if(type==POSITION_TYPE_SELL)
        {
         double n=sl;
         if(InpUseEarlyBE && (entry-ask)>=InpBETriggerPts*point)
            n=MathMin((sl==0.0?entry:n),entry-InpBELockPts*point);
         if(InpUseTrailing && (entry-ask)>=start)
            n=MathMin(n,ask+dist);
         n=NormalizeDouble(n,_Digits);
         if((sl==0.0||n<sl) && n>ask) trade.PositionModify(t,n,tp);
        }
     }
  }

//+==================================================================+
//|  FILTERS / GATES                                                 |
//+==================================================================+
bool CanTrade()
  {
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double dayPnl=eq-g_dayStartEq;
   if(g_dayStartEq>0 && (-dayPnl)/g_dayStartEq*100.0>=InpMaxDailyDD) g_haltDay=true;
   if(InpDailyProfitTgt>0.0 && dayPnl>=InpDailyProfitTgt) g_haltDay=true;
   if(InpDailyTargetPct>0.0 && g_dayStartEq>0 && dayPnl>=g_dayStartEq*InpDailyTargetPct/100.0) g_haltDay=true;
   if(g_haltDay){ g_status="daily target/DD reached"; return false; }
   if(IsHoliday()){ g_status="holiday: no trading"; return false; }
   if(!InSession()){ g_status="outside session"; return false; }
   if(NewsBlackout()){ g_status="news blackout: "+g_newsTxt; return false; }
   return true;
  }

bool InSession()
  {
   if(!InpUseSession) return true;
   MqlDateTime s; TimeToStruct(TimeCurrent(),s);
   bool dayOK=false;
   switch(s.day_of_week)
     {
      case 0: dayOK=InpTradeSun; break;
      case 1: dayOK=InpTradeMon; break;
      case 2: dayOK=InpTradeTue; break;
      case 3: dayOK=InpTradeWed; break;
      case 4: dayOK=InpTradeThu; break;
      case 5: dayOK=InpTradeFri; break;
      case 6: dayOK=InpTradeSat; break;
     }
   if(!dayOK) return false;
   int h=s.hour;
   if(InpSessionStart<=InpSessionEnd) return (h>=InpSessionStart && h<InpSessionEnd);
   return (h>=InpSessionStart || h<InpSessionEnd);   // overnight wrap
  }

bool IsHoliday()
  {
   if(InpHolidayDates=="") return false;
   MqlDateTime s; TimeToStruct(TimeCurrent(),s);
   string today=StringFormat("%04d.%02d.%02d",s.year,s.mon,s.day);
   return (StringFind(InpHolidayDates,today)>=0);
  }

bool NewsBlackout()
  {
   if(!InpUseNews) return false;
   datetime now=TimeCurrent();
   MqlCalendarValue values[];
   int n=CalendarValueHistory(values, now-InpNewsAfterMin*60, now+InpNewsBeforeMin*60, NULL, InpNewsCurrency);
   for(int i=0;i<n;i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id,ev)) continue;
      if((int)ev.importance>=InpNewsImportance){ g_newsTxt=ev.name; return true; }
     }
   g_newsTxt="";
   return false;
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
     { ulong t=PositionGetTicket(i); if(PositionSelectByTicket(t)&&PositionGetInteger(POSITION_MAGIC)==InpMagic&&PositionGetString(POSITION_SYMBOL)==_Symbol) c++; }
   return c;
  }
double BasketProfit()
  {
   double p=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     { ulong t=PositionGetTicket(i); if(PositionSelectByTicket(t)&&PositionGetInteger(POSITION_MAGIC)==InpMagic&&PositionGetString(POSITION_SYMBOL)==_Symbol) p+=PositionGetDouble(POSITION_PROFIT); }
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
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double lot;
   if(InpUseFixedLot)
      lot=InpFixedLot;                       // you set it directly
   else
     {
      double eq=AccountInfoDouble(ACCOUNT_EQUITY),riskMoney=eq*(InpRiskPct/100.0);
      double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE),ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
      if(tv<=0||ts<=0||slDist<=0) return 0.0;
      double lossPerLot=(slDist/ts)*tv; if(lossPerLot<=0) return 0.0;
      lot=riskMoney/lossPerLot;
     }
   if(step>0) lot=MathFloor(lot/step)*step;
   lot=MathMax(lot,vmin); lot=MathMin(lot,vmax);
   return NormalizeDouble(lot,2);
  }
void RollDay(){ datetime d=StartOfDay(TimeCurrent()); if(d!=g_day){ g_day=d; g_dayStartEq=AccountInfoDouble(ACCOUNT_EQUITY); g_haltDay=false; g_tradesToday=0; } }
datetime StartOfDay(datetime t){ MqlDateTime s; TimeToStruct(t,s); s.hour=0; s.min=0; s.sec=0; return StructToTime(s); }

//+==================================================================+
//|  TRADING PANEL                                                   |
//+==================================================================+
void Dashboard()
  {
   double atr=CurrentATR(),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double tpDist=atr*InpTPmult,spread=ask-bid,eq=AccountInfoDouble(ACCOUNT_EQUITY);
   string dir=(InpDirection==DIR_BOTH?"BUY+SELL":InpDirection==DIR_BUY_ONLY?"BUY only":"SELL only");
   string warn=(spread>=InpSpreadTPratio*tpDist)?"  (spread too wide!)":"";
   string s="";
   s+="============ LexiGoldScalper ============\n";
   s+=StringFormat("Symbol %s %s   Dir: %s\n",_Symbol,EnumToString(InpTF),dir);
   s+=StringFormat("EMA20 %.2f  EMA50 %.2f  RSI %.1f\n",EMA(hEf),EMA(hEs),RSIval());
   s+=StringFormat("ATR %.2f  TP %.2f  SL %.2f\n",atr,tpDist,atr*InpSLmult);
   s+=StringFormat("Spread %.2f%s\n",spread,warn);
   s+="-----------------------------------------\n";
   s+=StringFormat("Session %s   News %s   Holiday %s\n",(InSession()?"OPEN":"closed"),(InpUseNews?"on":"off"),(IsHoliday()?"YES":"no"));
   s+=StringFormat("Trades today %d   Open %d/%d\n",g_tradesToday,CountMine(),InpMaxPositions);
   s+=StringFormat("Day P/L %.2f %s   Floating %.2f\n",eq-g_dayStartEq,AccountInfoString(ACCOUNT_CURRENCY),BasketProfit());
   s+=StringFormat("Limits: DD %.0f%%  Target %.2f\n",InpMaxDailyDD,InpDailyProfitTgt);
   s+=StringFormat("Status: %s\n",g_status);
   s+="=========================================";
   Comment(s);
  }
//+------------------------------------------------------------------+
