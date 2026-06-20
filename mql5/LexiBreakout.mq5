//+------------------------------------------------------------------+
//|                                                  LexiBreakout.mq5 |
//|   Breakout trend-stacking EA (pending stop orders)               |
//|                                                                  |
//|   Places a stop order in the trend direction; when price breaks  |
//|   out it fills and a new stop is placed further along, STACKING  |
//|   positions WITH the trend (scale into winners). Each position   |
//|   carries its own stop-loss + early breakeven + trailing.        |
//|                                                                  |
//|   NOT martingale: it only adds in the breakout/trend direction,  |
//|   never averages down into a loss. On a reversal each stacked    |
//|   position is capped by its own SL (still a cluster of losses).  |
//|   TEST ON DEMO FIRST. High risk, no profit guaranteed.          |
//+------------------------------------------------------------------+
#property copyright "Lexi"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//--- Core -----------------------------------------------------------
input ENUM_TIMEFRAMES InpTF = PERIOD_M1;
input int    InpEmaFast   = 20;
input int    InpEmaSlow   = 50;
input int    InpATRPeriod = 14;

//--- Breakout / stacking -------------------------------------------
input double InpTriggerATR  = 0.30; // Stop order this far from price (x ATR)
input double InpMinDistPct  = 0.05; // Min distance as % of price (safety for fast symbols like BTC)
input double InpSLatr        = 1.20; // Stop-loss distance (x ATR)
input int    InpMaxPositions = 10;   // Max stacked positions
input bool   InpCloseOnFlip  = true; // Close opposite side when trend flips

//--- Take profit ----------------------------------------------------
input bool   InpUseQuickTP    = true; // Bank each position as soon as it shows a small profit
input double InpQuickTPmoney  = 1.0;  // Per-position profit to bank (account ccy)
input double InpBasketTPmoney = 0.0;  // Close ALL when total profit >= this (0=off)

//--- Position size --------------------------------------------------
input double InpRiskPct     = 0.25;
input bool   InpUseFixedLot = false;
input double InpFixedLot      = 0.02;

//--- Protect each position -----------------------------------------
input bool   InpUseEarlyBE   = true; // Move SL above entry on tiny profit
input int    InpBETriggerPts = 30;
input int    InpBELockPts     = 5;
input bool   InpUseTrailing  = true;
input int    InpTrailStartPts = 150;
input int    InpTrailDistPts  = 120;

//--- Failsafe -------------------------------------------------------
input double InpMaxDailyDD    = 5.0;
input double InpMaxSpreadPct = 0.05;

//--- General --------------------------------------------------------
input long   InpMagic     = 770125;
input int    InpSlippagePts = 50;
input bool   InpDashboard = true;

//--- Globals --------------------------------------------------------
CTrade   trade;
int      hEf=INVALID_HANDLE,hEs=INVALID_HANDLE,hATR=INVALID_HANDLE;
datetime g_lastBar=0,g_day=0;
double   g_dayStartEq=0;
bool     g_haltDay=false;
string   g_status="init";

//+------------------------------------------------------------------+
int OnInit()
  {
   hEf =iMA(_Symbol,InpTF,InpEmaFast,0,MODE_EMA,PRICE_CLOSE);
   hEs =iMA(_Symbol,InpTF,InpEmaSlow,0,MODE_EMA,PRICE_CLOSE);
   hATR=iATR(_Symbol,InpTF,InpATRPeriod);
   if(hEf==INVALID_HANDLE||hEs==INVALID_HANDLE||hATR==INVALID_HANDLE)
     { Print("ERROR: handles failed"); return(INIT_FAILED); }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);
   g_day=StartOfDay(TimeCurrent());
   g_dayStartEq=AccountInfoDouble(ACCOUNT_EQUITY);
   PrintFormat("LexiBreakout on %s %s",_Symbol,EnumToString(InpTF));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(hEf!=INVALID_HANDLE) IndicatorRelease(hEf);
   if(hEs!=INVALID_HANDLE) IndicatorRelease(hEs);
   if(hATR!=INVALID_HANDLE) IndicatorRelease(hATR);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   RollDay();
   QuickTP();                          // bank small profits immediately
   ManageProtection();                 // BE + trailing on every tick

   datetime bt=iTime(_Symbol,InpTF,0);
   if(bt!=g_lastBar)
     {
      g_lastBar=bt;
      int trend=Trend();

      if(InpCloseOnFlip && trend!=0)
        {
         if(trend>0) CloseSide(-1);     // flipped up -> drop shorts
         else        CloseSide(1);      // flipped down -> drop longs
        }

      DeleteMyPending();                // refresh the breakout order each bar
      if(CanTrade() && trend!=0 && CountMyPositions()<InpMaxPositions)
         PlaceStop(trend);
      else if(trend==0) g_status="no trend";
     }
   if(InpDashboard) Dashboard();
  }

//+==================================================================+
//|  BREAKOUT ORDER                                                  |
//+==================================================================+
void PlaceStop(int trend)
  {
   if(SpreadPct()>InpMaxSpreadPct){ g_status="spread too high"; return; }
   double atr=CurrentATR(); if(atr<=0.0){ g_status="no ATR"; return; }
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   long   stops=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   // Minimum safe distance: broker stops-level, OR a % of price (covers
   // fast instruments like BTC where a tiny trigger gets crossed instantly).
   double minDist=MathMax((double)(stops+20)*point, ask*InpMinDistPct/100.0);
   double trig=MathMax(InpTriggerATR*atr,minDist);   // stop order distance
   double slDist=MathMax(InpSLatr*atr,minDist);      // SL distance
   double lot=CalcLot(slDist); if(lot<=0.0){ g_status="lot=0"; return; }

   if(trend>0)
     {
      double price=NormalizeDouble(ask+trig,_Digits);
      double sl=NormalizeDouble(price-slDist,_Digits);
      if(trade.BuyStop(lot,price,_Symbol,sl,0.0,ORDER_TIME_GTC,0,"LexiBreakout"))
         g_status="buy-stop placed (uptrend)";
      else
        { g_status=StringFormat("buy-stop FAILED: %d %s",trade.ResultRetcode(),trade.ResultRetcodeDescription());
          Print(g_status); }
     }
   else
     {
      double price=NormalizeDouble(bid-trig,_Digits);
      double sl=NormalizeDouble(price+slDist,_Digits);
      if(trade.SellStop(lot,price,_Symbol,sl,0.0,ORDER_TIME_GTC,0,"LexiBreakout"))
         g_status="sell-stop placed (downtrend)";
      else
        { g_status=StringFormat("sell-stop FAILED: %d %s",trade.ResultRetcode(),trade.ResultRetcodeDescription());
          Print(g_status); }
     }
  }

//+==================================================================+
//|  TAKE PROFIT (per-position quick TP + basket TP)                 |
//+==================================================================+
void QuickTP()
  {
   // Basket: close everything once combined profit hits the target.
   if(InpBasketTPmoney>0.0 && BasketProfit()>=InpBasketTPmoney)
     {
      CloseSide(1); CloseSide(-1); DeleteMyPending();
      g_status="basket TP banked";
      return;
     }
   // Per-position: bank each as soon as it shows the small profit.
   if(InpUseQuickTP && InpQuickTPmoney>0.0)
     {
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong t=PositionGetTicket(i);
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         if(PositionGetDouble(POSITION_PROFIT)>=InpQuickTPmoney) trade.PositionClose(t);
        }
     }
  }

//+==================================================================+
//|  PER-POSITION PROTECTION (breakeven + trailing)                  |
//+==================================================================+
void ManageProtection()
  {
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long type=PositionGetInteger(POSITION_TYPE);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP);
      if(type==POSITION_TYPE_BUY)
        {
         double n=sl;
         if(InpUseEarlyBE && (bid-entry)>=InpBETriggerPts*point) n=MathMax(n,entry+InpBELockPts*point);
         if(InpUseTrailing && (bid-entry)>=InpTrailStartPts*point) n=MathMax(n,bid-InpTrailDistPts*point);
         n=NormalizeDouble(n,_Digits);
         if(n>sl && n<bid) trade.PositionModify(t,n,tp);
        }
      else if(type==POSITION_TYPE_SELL)
        {
         double n=sl;
         if(InpUseEarlyBE && (entry-ask)>=InpBETriggerPts*point) n=MathMin((sl==0.0?entry:n),entry-InpBELockPts*point);
         if(InpUseTrailing && (entry-ask)>=InpTrailStartPts*point) n=MathMin(n,ask+InpTrailDistPts*point);
         n=NormalizeDouble(n,_Digits);
         if((sl==0.0||n<sl) && n>ask) trade.PositionModify(t,n,tp);
        }
     }
  }

//+==================================================================+
//|  HELPERS                                                         |
//+==================================================================+
int Trend()
  {
   double ef[1],es[1];
   if(CopyBuffer(hEf,0,1,1,ef)<1) return 0;
   if(CopyBuffer(hEs,0,1,1,es)<1) return 0;
   if(ef[0]>es[0]) return 1;
   if(ef[0]<es[0]) return -1;
   return 0;
  }
double CurrentATR(){ double b[1]; if(CopyBuffer(hATR,0,1,1,b)<1) return 0.0; return b[0]; }
double SpreadPct(){ double a=SymbolInfoDouble(_Symbol,SYMBOL_ASK),b=SymbolInfoDouble(_Symbol,SYMBOL_BID); if(b<=0) return 0.0; return (a-b)/b*100.0; }

int CountMyPositions()
  {
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     { ulong t=PositionGetTicket(i); if(PositionSelectByTicket(t)&&PositionGetInteger(POSITION_MAGIC)==InpMagic&&PositionGetString(POSITION_SYMBOL)==_Symbol) c++; }
   return c;
  }
int CountMyPending()
  {
   int c=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
     { ulong t=OrderGetTicket(i); if(t>0 && OrderGetInteger(ORDER_MAGIC)==InpMagic && OrderGetString(ORDER_SYMBOL)==_Symbol) c++; }
   return c;
  }
void DeleteMyPending()
  {
   for(int i=OrdersTotal()-1;i>=0;i--)
     { ulong t=OrderGetTicket(i); if(t>0 && OrderGetInteger(ORDER_MAGIC)==InpMagic && OrderGetString(ORDER_SYMBOL)==_Symbol) trade.OrderDelete(t); }
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
   if(InpUseFixedLot) lot=InpFixedLot;
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
bool CanTrade()
  {
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_dayStartEq>0 && (g_dayStartEq-eq)/g_dayStartEq*100.0>=InpMaxDailyDD) g_haltDay=true;
   if(g_haltDay){ g_status="daily DD halt"; return false; }
   return true;
  }
void RollDay(){ datetime d=StartOfDay(TimeCurrent()); if(d!=g_day){ g_day=d; g_dayStartEq=AccountInfoDouble(ACCOUNT_EQUITY); g_haltDay=false; } }
datetime StartOfDay(datetime t){ MqlDateTime s; TimeToStruct(t,s); s.hour=0; s.min=0; s.sec=0; return StructToTime(s); }

//+==================================================================+
//|  DASHBOARD                                                       |
//+==================================================================+
void Dashboard()
  {
   int tr=Trend();
   string td=(tr>0?"UPTREND (stack BUY)":tr<0?"DOWNTREND (stack SELL)":"no trend");
   string s="";
   s+="============== LexiBreakout ==============\n";
   s+=StringFormat("Trend       : %s\n",td);
   s+=StringFormat("Stacked pos : %d / %d\n",CountMyPositions(),InpMaxPositions);
   s+=StringFormat("Pending     : %d   Spread %.3f%%\n",CountMyPending(),SpreadPct());
   s+=StringFormat("Floating    : %.2f %s\n",BasketProfit(),AccountInfoString(ACCOUNT_CURRENCY));
   s+=StringFormat("Day P/L     : %.2f\n",AccountInfoDouble(ACCOUNT_EQUITY)-g_dayStartEq);
   s+=StringFormat("Status      : %s\n",g_status);
   s+="==========================================";
   Comment(s);
  }
//+------------------------------------------------------------------+
