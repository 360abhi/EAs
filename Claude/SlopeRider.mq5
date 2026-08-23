//+------------------------------------------------------------------+
//|                                                   SlopeRider.mq5 |
//|  v1.0 — Intraday dual-timeframe MA SLOPE-ANGLE strategy          |
//|                                                                  |
//|  Core idea: trade only when the HIGHER-timeframe moving average  |
//|  is rising/falling at a sufficient ANGLE — not merely when price |
//|  is above/below it — and time entries on the LOWER timeframe     |
//|  with its own slope conditions.                                  |
//|                                                                  |
//|  Slope-angle definition (scale-invariant):                       |
//|     angle = atan( (MA[1] - MA[1+L]) / (L * ATR) ) * 180/pi       |
//|  The MA change over L bars is normalized by ATR of the same      |
//|  timeframe, so "30 degrees" means the same trend intensity on    |
//|  any symbol/timeframe. Raw price-unit slopes are chart-scale     |
//|  dependent and meaningless — do not compare this EA's angles to  |
//|  angles eyeballed on a chart.                                    |
//|                                                                  |
//|  Two entry models (each can be disabled):                        |
//|   A) PULLBACK: HTF angle >= threshold; LTF price pulls back to   |
//|      the LTF EMA while the LTF angle stays above a floor; entry  |
//|      on a stop order above the pullback bar.                     |
//|   B) IGNITION: LTF angle crosses UP through an ignition          |
//|      threshold (slope acceleration) while HTF is aligned and     |
//|      price is on the right side of the LTF EMA. Market entry.    |
//|                                                                  |
//|  Intraday by construction: session window, EOD flat, daily       |
//|  equity stop, per-day trade cap.                                 |
//|                                                                  |
//|  NOT financial advice. Validate per your 100-150 trade protocol  |
//|  with IS/OOS split before any live use.                          |
//+------------------------------------------------------------------+
#property copyright "Original implementation"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//=================== INPUTS =========================================
input group "=== Risk & Session ==="
input double InpRiskPercent     = 0.5;      // Risk % of equity per trade
input double InpDailyLossPct    = 2.0;      // Daily equity stop % (0 = off)
input int    InpMaxTradesPerDay = 2;        // Max entries per day
input int    InpMaxSpreadPoints = 30;       // Max spread (points)
input long   InpMagic           = 772800;   // Magic number
input int    InpSessStartHour   = 16;       // Session start hour (SERVER time)
input int    InpSessStartMin    = 35;       // Session start minute
input int    InpLastEntryHour   = 20;       // Last new-entry hour (server)
input int    InpLastEntryMin    = 0;        // Last new-entry minute
input int    InpFlatHour        = 22;       // Hard flat hour (server)
input int    InpFlatMin         = 55;       // Hard flat minute
// NOTE: defaults assume a GMT+2/+3 server where NY 09:35 ET ~ 16:35.
// Verify your broker's offset and adjust — wrong session times are the
// #1 cause of "why doesn't it trade" reports.

input group "=== Higher timeframe (regime) ==="
input ENUM_TIMEFRAMES InpHTF        = PERIOD_H1;
input int             InpHTF_MAPer  = 50;     // HTF MA period
input ENUM_MA_METHOD  InpHTF_MAMeth = MODE_EMA;
input int             InpHTF_SlopeL = 5;      // Slope lookback (HTF bars)
input int             InpHTF_ATRPer = 14;     // ATR period for normalization
input double          InpHTF_MinAng = 20.0;   // Min HTF angle (degrees) to allow trades
input double          InpHTF_ExitAng= 5.0;    // Slope-exit when HTF angle falls below (0=off)

input group "=== Lower timeframe (execution) ==="
input ENUM_TIMEFRAMES InpLTF        = PERIOD_M5;
input int             InpLTF_MAPer  = 20;     // LTF EMA period
input ENUM_MA_METHOD  InpLTF_MAMeth = MODE_EMA;
input int             InpLTF_SlopeL = 4;      // Slope lookback (LTF bars)
input int             InpLTF_ATRPer = 14;     // ATR period for normalization

input group "=== Entry A: Pullback ==="
input bool   InpUsePullback     = true;
input double InpPB_TouchATR     = 0.25;     // Bar counts as EMA touch if within x ATR
input double InpPB_MinLTFAng    = -10.0;    // LTF angle floor during pullback (deg)
input int    InpPB_OrderExpiryBars = 3;     // Pending order lifetime (LTF bars)

input group "=== Entry B: Slope Ignition ==="
input bool   InpUseIgnition     = true;
input double InpIG_Threshold    = 25.0;     // LTF angle must cross above this (deg)
input double InpIG_PrevBelow    = 15.0;     // ...having been below this on the prior bar

input group "=== Exits ==="
input double InpSL_ATRMult      = 1.5;      // Initial stop, x ATR(LTF)
input double InpTP_RR           = 2.0;      // Take profit in R multiples (0 = none)
input bool   InpBreakevenAt1R   = true;     // SL to BE at +1R
input double InpTrail_ATRMult   = 2.0;      // ATR(LTF) trail (0 = off)
input bool   InpUseSlopeExit    = true;     // Exit when HTF angle decays below ExitAng

//=================== INTERNALS ======================================
CTrade trade;
int hMA_H=INVALID_HANDLE, hATR_H=INVALID_HANDLE;
int hMA_L=INVALID_HANDLE, hATR_L=INVALID_HANDLE;

datetime lastLTFBar=0, lastDay=0;
int      tradesToday=0;
double   dayStartEq=0.0;
bool     dayHalted=false;
datetime pendingPlacedBar=0;

//=================== HELPERS ========================================
double Ind(int handle,int shift)
  {
   double b[1];
   if(CopyBuffer(handle,0,shift,1,b)!=1) return EMPTY_VALUE;
   return b[0];
  }

// ATR-normalized slope angle in degrees on closed bars (shift 1 vs 1+L)
double SlopeAngle(int hMA,int hATR,int lookback)
  {
   double maNow=Ind(hMA,1);
   double maOld=Ind(hMA,1+lookback);
   double atr  =Ind(hATR,1);
   if(maNow==EMPTY_VALUE||maOld==EMPTY_VALUE||atr==EMPTY_VALUE||atr<=0) return EMPTY_VALUE;
   double slopePerBar=(maNow-maOld)/(lookback*atr);
   return MathArctan(slopePerBar)*180.0/M_PI;
  }
// Same angle one bar earlier (for cross detection)
double SlopeAnglePrev(int hMA,int hATR,int lookback)
  {
   double maNow=Ind(hMA,2);
   double maOld=Ind(hMA,2+lookback);
   double atr  =Ind(hATR,2);
   if(maNow==EMPTY_VALUE||maOld==EMPTY_VALUE||atr==EMPTY_VALUE||atr<=0) return EMPTY_VALUE;
   return MathArctan((maNow-maOld)/(lookback*atr))*180.0/M_PI;
  }

double LO(int i){ return iOpen (_Symbol,InpLTF,i); }
double LH(int i){ return iHigh (_Symbol,InpLTF,i); }
double LL(int i){ return iLow  (_Symbol,InpLTF,i); }
double LC(int i){ return iClose(_Symbol,InpLTF,i); }

bool SpreadOK(){ return SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)<=InpMaxSpreadPoints; }

bool InEntryWindow()
  {
   MqlDateTime t; TimeToStruct(TimeCurrent(),t);
   int now=t.hour*60+t.min;
   int s=InpSessStartHour*60+InpSessStartMin;
   int e=InpLastEntryHour*60+InpLastEntryMin;
   return (now>=s && now<=e);
  }
bool PastFlatTime()
  {
   MqlDateTime t; TimeToStruct(TimeCurrent(),t);
   return (t.hour*60+t.min >= InpFlatHour*60+InpFlatMin);
  }

int MyPositions()
  {
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic) n++;
     }
   return n;
  }
int MyOrders()
  {
   int n=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong tk=OrderGetTicket(i);
      if(tk==0) continue;
      if(OrderGetString(ORDER_SYMBOL)==_Symbol &&
         OrderGetInteger(ORDER_MAGIC)==InpMagic) n++;
     }
   return n;
  }
void CancelMyOrders()
  {
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong tk=OrderGetTicket(i);
      if(tk==0) continue;
      if(OrderGetString(ORDER_SYMBOL)==_Symbol &&
         OrderGetInteger(ORDER_MAGIC)==InpMagic) trade.OrderDelete(tk);
     }
  }
void CloseMyPositions()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic) trade.PositionClose(tk);
     }
  }

double LotsForRisk(double slDistance)
  {
   if(slDistance<=0) return 0.0;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double riskCash=eq*InpRiskPercent/100.0;
   double tickVal =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickVal<=0||tickSize<=0) return 0.0;
   double lossPerLot=slDistance/tickSize*tickVal;
   if(lossPerLot<=0) return 0.0;
   double lots=riskCash/lossPerLot;
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   lots=MathFloor(lots/step)*step;
   if(lots<vmin) return 0.0;
   if(lots>vmax) lots=vmax;
   return NormalizeDouble(lots,2);
  }

//=================== ENTRY LOGIC (on new LTF bar) ===================
void CheckEntries()
  {
   if(!InEntryWindow() || !SpreadOK())               return;
   if(tradesToday>=InpMaxTradesPerDay)               return;
   if(MyPositions()>0)                               return;

   double angH=SlopeAngle(hMA_H,hATR_H,InpHTF_SlopeL);
   double angL=SlopeAngle(hMA_L,hATR_L,InpLTF_SlopeL);
   double angLp=SlopeAnglePrev(hMA_L,hATR_L,InpLTF_SlopeL);
   double emaL=Ind(hMA_L,1);
   double atrL=Ind(hATR_L,1);
   if(angH==EMPTY_VALUE||angL==EMPTY_VALUE||angLp==EMPTY_VALUE||
      emaL==EMPTY_VALUE||atrL==EMPTY_VALUE||atrL<=0)  return;

   bool regimeLong =(angH>= InpHTF_MinAng);
   bool regimeShort=(angH<=-InpHTF_MinAng);
   if(!regimeLong && !regimeShort) return;             // HTF slope too flat: no trades

   double buf=3*_Point;

   //--- Entry A: PULLBACK (stop order beyond the pullback bar) ------
   if(InpUsePullback && MyOrders()==0)
     {
      if(regimeLong)
        {
         bool touched =(LL(1)<=emaL+InpPB_TouchATR*atrL);   // bar 1 tagged the EMA zone
         bool heldOver=(LC(1)>emaL);                        // ...but closed back above
         bool slopeOK =(angL>=InpPB_MinLTFAng);             // LTF slope not collapsing
         if(touched && heldOver && slopeOK)
           {
            double entry=LH(1)+buf;
            double sl   =MathMin(LL(1),emaL)-buf;
            if(entry-sl < 0.5*atrL) sl=entry-InpSL_ATRMult*atrL;   // enforce sane stop
            if(entry-sl > 3.0*atrL) sl=entry-InpSL_ATRMult*atrL;
            PlaceStopOrder(true,entry,sl);
           }
        }
      if(regimeShort)
        {
         bool touched =(LH(1)>=emaL-InpPB_TouchATR*atrL);
         bool heldOver=(LC(1)<emaL);
         bool slopeOK =(angL<=-InpPB_MinLTFAng);
         if(touched && heldOver && slopeOK)
           {
            double entry=LL(1)-buf;
            double sl   =MathMax(LH(1),emaL)+buf;
            if(sl-entry < 0.5*atrL) sl=entry+InpSL_ATRMult*atrL;
            if(sl-entry > 3.0*atrL) sl=entry+InpSL_ATRMult*atrL;
            PlaceStopOrder(false,entry,sl);
           }
        }
     }

   //--- Entry B: SLOPE IGNITION (market order on angle cross) -------
   if(InpUseIgnition)
     {
      if(regimeLong &&
         angLp< InpIG_PrevBelow && angL>= InpIG_Threshold &&   // fresh acceleration
         LC(1)>emaL)                                           // on the right side
        {
         double px=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         double sl=px-InpSL_ATRMult*atrL;
         MarketEntry(true,px,sl);
        }
      if(regimeShort &&
         angLp>-InpIG_PrevBelow && angL<=-InpIG_Threshold &&
         LC(1)<emaL)
        {
         double px=SymbolInfoDouble(_Symbol,SYMBOL_BID);
         double sl=px+InpSL_ATRMult*atrL;
         MarketEntry(false,px,sl);
        }
     }
  }

void PlaceStopOrder(bool isLong,double entry,double sl)
  {
   entry=NormalizeDouble(entry,_Digits);
   sl   =NormalizeDouble(sl,_Digits);
   double dist=MathAbs(entry-sl);
   double lots=LotsForRisk(dist);
   if(lots<=0) return;
   double tp=0;
   if(InpTP_RR>0) tp=NormalizeDouble(isLong? entry+InpTP_RR*dist : entry-InpTP_RR*dist,_Digits);
   trade.SetExpertMagicNumber(InpMagic);
   datetime exp=iTime(_Symbol,InpLTF,0)+InpPB_OrderExpiryBars*PeriodSeconds(InpLTF);
   bool ok=(isLong? trade.BuyStop (lots,entry,_Symbol,sl,tp,ORDER_TIME_SPECIFIED,exp,"PB")
                  : trade.SellStop(lots,entry,_Symbol,sl,tp,ORDER_TIME_SPECIFIED,exp,"PB"));
   if(ok)
     {
      pendingPlacedBar=iTime(_Symbol,InpLTF,0);
      PrintFormat("[PB] %s stop %.5f SL %.5f lots %.2f",(isLong?"BUY":"SELL"),entry,sl,lots);
     }
  }

void MarketEntry(bool isLong,double px,double sl)
  {
   sl=NormalizeDouble(sl,_Digits);
   double dist=MathAbs(px-sl);
   double lots=LotsForRisk(dist);
   if(lots<=0) return;
   double tp=0;
   if(InpTP_RR>0) tp=NormalizeDouble(isLong? px+InpTP_RR*dist : px-InpTP_RR*dist,_Digits);
   trade.SetExpertMagicNumber(InpMagic);
   bool ok=(isLong? trade.Buy (lots,_Symbol,0,sl,tp,"IG")
                  : trade.Sell(lots,_Symbol,0,sl,tp,"IG"));
   if(ok)
     {
      tradesToday++;
      PrintFormat("[IG] %s market SL %.5f lots %.2f",(isLong?"BUY":"SELL"),sl,lots);
     }
  }

//=================== MANAGEMENT =====================================
void ManagePositions()
  {
   double atrL=Ind(hATR_L,1);
   double angH=SlopeAngle(hMA_H,hATR_H,InpHTF_SlopeL);

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      long   type =PositionGetInteger(POSITION_TYPE);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   =PositionGetDouble(POSITION_SL);
      double tp   =PositionGetDouble(POSITION_TP);
      bool   isL  =(type==POSITION_TYPE_BUY);
      double cur  =(isL? SymbolInfoDouble(_Symbol,SYMBOL_BID)
                       : SymbolInfoDouble(_Symbol,SYMBOL_ASK));

      // 1) hard EOD flat
      if(PastFlatTime()){ trade.PositionClose(tk); continue; }

      // 2) slope-decay exit: the reason for the trade is gone
      if(InpUseSlopeExit && angH!=EMPTY_VALUE && InpHTF_ExitAng>0)
        {
         if(isL  && angH< InpHTF_ExitAng){ trade.PositionClose(tk); continue; }
         if(!isL && angH>-InpHTF_ExitAng){ trade.PositionClose(tk); continue; }
        }

      // 3) breakeven at +1R
      if(InpBreakevenAt1R && sl>0)
        {
         double r=MathAbs(entry-sl);
         if(isL  && cur>=entry+r && sl<entry)
            trade.PositionModify(tk,NormalizeDouble(entry+3*_Point,_Digits),tp);
         if(!isL && cur<=entry-r && sl>entry)
            trade.PositionModify(tk,NormalizeDouble(entry-3*_Point,_Digits),tp);
        }

      // 4) ATR trail
      if(InpTrail_ATRMult>0 && atrL!=EMPTY_VALUE && atrL>0)
        {
         if(isL)
           {
            double t=NormalizeDouble(cur-InpTrail_ATRMult*atrL,_Digits);
            if(t>sl && t<cur) trade.PositionModify(tk,t,tp);
           }
         else
           {
            double t=NormalizeDouble(cur+InpTrail_ATRMult*atrL,_Digits);
            if((sl==0||t<sl) && t>cur) trade.PositionModify(tk,t,tp);
           }
        }
     }
  }

//=================== MQL5 EVENTS ====================================
int OnInit()
  {
   trade.SetDeviationInPoints(20);
   hMA_H =iMA (_Symbol,InpHTF,InpHTF_MAPer,0,InpHTF_MAMeth,PRICE_CLOSE);
   hATR_H=iATR(_Symbol,InpHTF,InpHTF_ATRPer);
   hMA_L =iMA (_Symbol,InpLTF,InpLTF_MAPer,0,InpLTF_MAMeth,PRICE_CLOSE);
   hATR_L=iATR(_Symbol,InpLTF,InpLTF_ATRPer);
   if(hMA_H==INVALID_HANDLE||hATR_H==INVALID_HANDLE||
      hMA_L==INVALID_HANDLE||hATR_L==INVALID_HANDLE)
     { Print("Indicator handle failed"); return INIT_FAILED; }
   Print("SlopeRider v1.0 | HTF ",EnumToString(InpHTF)," MA",InpHTF_MAPer,
         " minAngle ",InpHTF_MinAng,"deg | LTF ",EnumToString(InpLTF),
         " | session ",InpSessStartHour,":",InpSessStartMin,"-",InpFlatHour,":",InpFlatMin," server");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   IndicatorRelease(hMA_H); IndicatorRelease(hATR_H);
   IndicatorRelease(hMA_L); IndicatorRelease(hATR_L);
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   // count pending-order fills toward the daily cap
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD &&
      trans.symbol==_Symbol && trans.deal_type<=DEAL_TYPE_SELL)
     {
      // entries only (deal entry IN)
      HistorySelect(TimeCurrent()-86400,TimeCurrent()+60);
      ulong deal=trans.deal;
      if(HistoryDealGetInteger(deal,DEAL_MAGIC)==InpMagic &&
         HistoryDealGetInteger(deal,DEAL_ENTRY)==DEAL_ENTRY_IN)
         tradesToday++;
     }
  }

void OnTick()
  {
   // day rollover
   datetime d1=iTime(_Symbol,PERIOD_D1,0);
   if(d1!=lastDay)
     {
      lastDay=d1;
      tradesToday=0;
      dayStartEq=AccountInfoDouble(ACCOUNT_EQUITY);
      dayHalted=false;
      CancelMyOrders();
     }

   if(dayHalted) return;
   if(InpDailyLossPct>0 && dayStartEq>0 &&
      AccountInfoDouble(ACCOUNT_EQUITY)<=dayStartEq*(1.0-InpDailyLossPct/100.0))
     {
      dayHalted=true;
      CancelMyOrders(); CloseMyPositions();
      Print("Daily equity stop hit — flat until tomorrow.");
      return;
     }

   // outside session: keep managing, cancel stale pendings after flat time
   if(PastFlatTime()){ CancelMyOrders(); }

   ManagePositions();

   // entries on new LTF bar only
   datetime lb=iTime(_Symbol,InpLTF,0);
   if(lb!=lastLTFBar)
     {
      lastLTFBar=lb;
      CheckEntries();
     }
  }
//+------------------------------------------------------------------+