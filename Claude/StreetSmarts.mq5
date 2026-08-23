//+------------------------------------------------------------------+
//|                                              StreetSmartsEA.mq5  |
//|  v1.0 — Clean-room MQL5 implementation of the RULE-BASED setups  |
//|  popularized in Raschke & Connors' "Street Smarts" (1996).       |
//|                                                                  |
//|  All rules are paraphrased/re-engineered from public knowledge   |
//|  of these classic setups — no book text is reproduced. Verify    |
//|  behaviour against your own copy of the book before trusting it. |
//|                                                                  |
//|  Strategies (each with its own magic number, enable flag):       |
//|   1 TSOUP    Turtle Soup            (20-day false-break fade)    |
//|   2 TSOUP1   Turtle Soup Plus One   (next-day version)           |
//|   3 EIGHTY20 80-20's                (open/close range reversal)  |
//|   4 MOMPIN   Momentum Pinball       (LBR/RSI + 1st-hour break)   |
//|   5 GRAIL    Holy Grail             (ADX>30 pullback to 20EMA)   |
//|   6 ANTI     The Anti               (stoch hook with %D trend)   |
//|   7 IDNR4    ID/NR4 Breakout        (inside + narrowest of 4)    |
//|   8 WHOOPS   Whoops / gap fade      (open gap beyond prior bar)  |
//|   9 SMASH    Smash Day              (wide reversal-bar trap)     |
//|                                                                  |
//|  Design: daily-bar logic on PERIOD_D1 of the chart symbol,       |
//|  tick-level triggers where the setup demands it (Turtle Soup,    |
//|  80-20's). Fixed-fractional risk sizing, spread gate, daily      |
//|  equity stop, per-strategy time exits.                          |
//|                                                                  |
//|  NOT financial advice. Backtest & forward-test before live use.  |
//+------------------------------------------------------------------+
#property copyright "Clean-room implementation"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//=================== GENERAL INPUTS =================================
input group "=== Risk & General ==="
input double InpRiskPercent      = 0.5;    // Risk % of equity per trade
input double InpDailyLossPct     = 2.0;    // Daily equity stop % (0 = off)
input int    InpMaxSpreadPoints  = 30;     // Max spread (points) to trade
input long   InpMagicBase        = 772600; // Magic number base
input int    InpBufferPoints     = 3;      // Entry/stop buffer (points)
input int    InpEODHour          = 23;     // End-of-day flat hour (server)
input int    InpEODMinute        = 45;     // End-of-day flat minute
input double InpATRTrailMult     = 2.0;    // ATR(14,D1) trailing mult (0=off)
input bool   InpBreakevenAt1R    = true;   // Move SL to BE at +1R

input group "=== 1) Turtle Soup ==="
input bool   InpUseTSoup         = true;
input int    InpTS_Lookback      = 20;     // Channel lookback (days)
input int    InpTS_MinAge        = 4;      // Prior extreme must be >= N days old
input int    InpTS_TriggerPts    = 10;     // Must trade N pts beyond old extreme first
input int    InpTS_TimeExitDays  = 2;      // Time exit (bars in trade)

input group "=== 2) Turtle Soup Plus One ==="
input bool   InpUseTSoup1        = true;
input int    InpTS1_TimeExitDays = 4;

input group "=== 3) 80-20's ==="
input bool   InpUse8020          = true;
input double InpEE_Band          = 0.20;   // Open/close band as fraction of range
input int    InpEE_TriggerPts    = 10;     // Must trade N pts beyond prior extreme first
input bool   InpEE_DayTrade      = true;   // Flat at EOD

input group "=== 4) Momentum Pinball ==="
input bool   InpUseMomPin        = true;
input int    InpMP_FirstHourMins = 60;     // First range window (minutes)
input double InpMP_BuyLevel      = 30.0;   // LBR/RSI buy threshold (below)
input double InpMP_SellLevel     = 70.0;   // LBR/RSI sell threshold (above)
input int    InpMP_TimeExitDays  = 2;

input group "=== 5) Holy Grail ==="
input bool   InpUseGrail         = true;
input int    InpHG_ADXPeriod     = 14;
input double InpHG_ADXLevel      = 30.0;
input int    InpHG_EMAPeriod     = 20;
input int    InpHG_SwingLookback = 10;     // Target = prior swing extreme lookback
input int    InpHG_TimeExitDays  = 8;

input group "=== 6) The Anti ==="
input bool   InpUseAnti          = true;
input int    InpAN_K             = 7;      // Stoch %K period
input int    InpAN_Slow          = 4;      // %K slowing
input int    InpAN_D             = 10;     // %D period
input int    InpAN_MinHookBars   = 2;      // Min bars %K moved against %D
input int    InpAN_TimeExitDays  = 4;

input group "=== 7) ID/NR4 ==="
input bool   InpUseIDNR4         = true;
input int    InpID_TimeExitDays  = 3;

input group "=== 8) Whoops (gap fade) ==="
input bool   InpUseWhoops        = true;
input int    InpWH_MinGapPts     = 20;     // Minimum gap size (points)
input bool   InpWH_DayTrade      = true;

input group "=== 9) Smash Day ==="
input bool   InpUseSmash         = true;
input bool   InpSM_UseHidden     = true;   // Also take hidden smash days
input double InpSM_HiddenBand    = 0.25;   // Close in extreme 25% of range
input int    InpSM_TimeExitDays  = 3;

//=================== INTERNALS ======================================
CTrade  trade;

#define N_STRATS 9
enum SS_ID { TSOUP=0, TSOUP1=1, EIGHTY20=2, MOMPIN=3, GRAIL=4, ANTI=5, IDNR4=6, WHOOPS=7, SMASH=8 };
string  StratName[N_STRATS] = {"TSOUP","TSOUP1","8020","MOMPIN","GRAIL","ANTI","IDNR4","WHOOPS","SMASH"};

// Per-strategy daily setup state (recomputed each new D1 bar)
struct Setup
  {
   bool     longArmed;      // setup exists for the day
   bool     shortArmed;
   bool     longTriggered;  // tick-condition met (e.g. traded below old low)
   bool     shortTriggered;
   double   longLevel;      // entry stop level
   double   shortLevel;
   double   longSL;         // initial protective stop
   double   shortSL;
   double   longTP;
   double   shortTP;
  };
Setup S[N_STRATS];

datetime lastD1Bar   = 0;
datetime dayStart    = 0;
double   dayStartEq  = 0.0;
bool     dayHalted   = false;
bool     mpRangeDone = false;   // Momentum Pinball first-hour orders placed
int      mpBias      = 0;       // +1 buy day, -1 sell day, 0 none

int hATR = INVALID_HANDLE, hADX = INVALID_HANDLE, hEMA = INVALID_HANDLE;
int hSTO = INVALID_HANDLE, hRSIROC = INVALID_HANDLE;
double rocBuf[];                // 1-day ROC series for LBR/RSI

//=================== HELPERS ========================================
double DO(int i){ return iOpen (_Symbol,PERIOD_D1,i); }
double DH(int i){ return iHigh (_Symbol,PERIOD_D1,i); }
double DL(int i){ return iLow  (_Symbol,PERIOD_D1,i); }
double DC(int i){ return iClose(_Symbol,PERIOD_D1,i); }

double Pt(){ return _Point; }
double Buf(){ return InpBufferPoints*_Point; }

double HHigh(int from,int count){ int idx=iHighest(_Symbol,PERIOD_D1,MODE_HIGH,count,from); return (idx<0? 0.0 : DH(idx)); }
double LLow (int from,int count){ int idx=iLowest (_Symbol,PERIOD_D1,MODE_LOW ,count,from); return (idx<0? 0.0 : DL(idx)); }
int    HHIdx(int from,int count){ return iHighest(_Symbol,PERIOD_D1,MODE_HIGH,count,from); }
int    LLIdx(int from,int count){ return iLowest (_Symbol,PERIOD_D1,MODE_LOW ,count,from); }

bool SpreadOK()
  {
   long sp = SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   return (sp<=InpMaxSpreadPoints);
  }

double ATRD1()
  {
   double b[1];
   if(CopyBuffer(hATR,0,1,1,b)!=1) return 0.0;
   return b[0];
  }

long MagicOf(int id){ return InpMagicBase+id; }

int PositionsOf(int id)
  {
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==MagicOf(id)) n++;
     }
   return n;
  }

int OrdersOf(int id)
  {
   int n=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong tk=OrderGetTicket(i);
      if(tk==0) continue;
      if(OrderGetString(ORDER_SYMBOL)==_Symbol && OrderGetInteger(ORDER_MAGIC)==MagicOf(id)) n++;
     }
   return n;
  }

void CancelOrdersOf(int id)
  {
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong tk=OrderGetTicket(i);
      if(tk==0) continue;
      if(OrderGetString(ORDER_SYMBOL)==_Symbol && OrderGetInteger(ORDER_MAGIC)==MagicOf(id))
         trade.OrderDelete(tk);
     }
  }

void ClosePositionsOf(int id)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==MagicOf(id))
         trade.PositionClose(tk);
     }
  }

double LotsForRisk(double slDistance)
  {
   if(slDistance<=0) return 0.0;
   double eq       = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskCash = eq*InpRiskPercent/100.0;
   double tickVal  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickVal<=0||tickSize<=0) return 0.0;
   double lossPerLot = slDistance/tickSize*tickVal;
   if(lossPerLot<=0) return 0.0;
   double lots = riskCash/lossPerLot;
   double step = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots/step)*step;
   if(lots<vmin) return 0.0;          // refuse to oversize risk on tiny stops? -> too small: skip
   if(lots>vmax) lots=vmax;
   return NormalizeDouble(lots,2);
  }

datetime TodayEOD()
  {
   MqlDateTime t; TimeToStruct(dayStart,t);
   t.hour=InpEODHour; t.min=InpEODMinute; t.sec=0;
   return StructToTime(t);
  }

bool PlaceStop(int id,bool isLong,double level,double sl,double tp,bool expireEOD)
  {
   if(!SpreadOK()) return false;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   level=NormalizeDouble(level,_Digits);
   sl   =NormalizeDouble(sl,_Digits);
   tp   =(tp>0? NormalizeDouble(tp,_Digits):0.0);
   double dist=MathAbs(level-sl);
   double lots=LotsForRisk(dist);
   if(lots<=0) return false;
   trade.SetExpertMagicNumber(MagicOf(id));
   datetime exp = expireEOD? TodayEOD() : 0;
   ENUM_ORDER_TYPE_TIME tt = expireEOD? ORDER_TIME_SPECIFIED : ORDER_TIME_DAY;
   bool ok=false;
   if(isLong)
     {
      if(level<=ask) return false;   // stop must be above market
      ok=trade.BuyStop(lots,level,_Symbol,sl,tp,tt,exp,StratName[id]);
     }
   else
     {
      if(level>=bid) return false;
      ok=trade.SellStop(lots,level,_Symbol,sl,tp,tt,exp,StratName[id]);
     }
   if(ok) PrintFormat("[%s] %s stop @ %.5f SL %.5f TP %.5f lots %.2f",
                      StratName[id],(isLong?"BUY":"SELL"),level,sl,tp,lots);
   return ok;
  }

int BarsInTrade(ulong ticket)
  {
   datetime opent=(datetime)PositionGetInteger(POSITION_TIME);
   int shift=iBarShift(_Symbol,PERIOD_D1,opent);
   return shift; // D1 bars elapsed since entry bar
  }

//=================== INDICATOR VALUES ===============================
bool ADXVals(double &adx1,double &adx2)
  {
   double b[2];
   if(CopyBuffer(hADX,0,1,2,b)!=2) return false;
   adx1=b[1]; adx2=b[0];                 // b[] is series-ordered? CopyBuffer returns oldest->newest
   // CopyBuffer(handle,buf,start,count,arr): arr[0]=oldest of the range
   adx2=b[0]; adx1=b[1];
   // start=1,count=2 -> bars 2 and 1 ; arr[0]=bar2, arr[1]=bar1
   adx1=b[1]; adx2=b[0];
   return true;
  }

double EMAVal(int shift)
  {
   double b[1];
   if(CopyBuffer(hEMA,0,shift,1,b)!=1) return 0.0;
   return b[0];
  }

bool StochVals(double &k1,double &k2,double &k3,double &d1,double &d2)
  {
   double kb[3],db[2];
   if(CopyBuffer(hSTO,0,1,3,kb)!=3) return false;   // kb[0]=bar3 .. kb[2]=bar1
   if(CopyBuffer(hSTO,1,1,2,db)!=2) return false;   // db[0]=bar2, db[1]=bar1
   k1=kb[2]; k2=kb[1]; k3=kb[0];
   d1=db[1]; d2=db[0];
   return true;
  }

// LBR/RSI: 3-period RSI of the 1-day rate of change, computed manually on D1 closes
double LBR_RSI(int shift)
  {
   int need=shift+40;
   double roc[]; ArrayResize(roc,need);
   for(int i=0;i<need;i++) roc[i]=DC(i)-DC(i+1);   // 1-day momentum, series order
   // Wilder RSI(3) on roc[] ending at 'shift'
   int per=3, start=shift+30;                      // seed 30 bars back
   double gain=0,loss=0;
   for(int i=start;i>start-per;i--)
     {
      double d=roc[i]-roc[i+1];
      if(d>0) gain+=d; else loss-=d;
     }
   double ag=gain/per, al=loss/per;
   for(int i=start-per;i>=shift;i--)
     {
      double d=roc[i]-roc[i+1];
      ag=(ag*(per-1)+(d>0? d:0))/per;
      al=(al*(per-1)+(d<0? -d:0))/per;
     }
   if(al==0) return 100.0;
   double rs=ag/al;
   return 100.0-100.0/(1.0+rs);
  }

//=================== DAILY SETUP SCAN ===============================
void ResetSetups()
  {
   for(int i=0;i<N_STRATS;i++)
     {
      S[i].longArmed=S[i].shortArmed=false;
      S[i].longTriggered=S[i].shortTriggered=false;
      S[i].longLevel=S[i].shortLevel=0;
      S[i].longSL=S[i].shortSL=0;
      S[i].longTP=S[i].shortTP=0;
     }
   mpRangeDone=false; mpBias=0;
  }

void ScanDailySetups()
  {
   ResetSetups();
   double atr=ATRD1();

   //--- 1) TURTLE SOUP -------------------------------------------------
   // Buy: the prior 20-day low (bars 1..N) was set >= MinAge days ago.
   // If today trades TriggerPts below it, arm a buy stop back at the level.
   if(InpUseTSoup)
     {
      int lidx=LLIdx(1,InpTS_Lookback);
      if(lidx>=1+InpTS_MinAge)                    // extreme old enough
        {
         S[TSOUP].longArmed=true;
         S[TSOUP].longLevel=LLow(1,InpTS_Lookback)+Buf();
        }
      int hidx=HHIdx(1,InpTS_Lookback);
      if(hidx>=1+InpTS_MinAge)
        {
         S[TSOUP].shortArmed=true;
         S[TSOUP].shortLevel=HHigh(1,InpTS_Lookback)-Buf();
        }
     }

   //--- 2) TURTLE SOUP PLUS ONE ----------------------------------------
   // Yesterday closed at/below the prior 20-day low (set >= MinAge days
   // before yesterday). Today: buy stop at that old low. Mirror for shorts.
   if(InpUseTSoup1)
     {
      double oldLow =LLow (2,InpTS_Lookback);
      int    oldLIdx=LLIdx(2,InpTS_Lookback);
      if(oldLIdx>=2+InpTS_MinAge && DC(1)<=oldLow && DL(1)<oldLow)
        {
         S[TSOUP1].longArmed=true;
         S[TSOUP1].longLevel=oldLow+Buf();
         S[TSOUP1].longSL   =MathMin(DL(1),LLow(1,1))-Buf();
        }
      double oldHigh =HHigh(2,InpTS_Lookback);
      int    oldHIdx =HHIdx(2,InpTS_Lookback);
      if(oldHIdx>=2+InpTS_MinAge && DC(1)>=oldHigh && DH(1)>oldHigh)
        {
         S[TSOUP1].shortArmed=true;
         S[TSOUP1].shortLevel=oldHigh-Buf();
         S[TSOUP1].shortSL   =DH(1)+Buf();
        }
     }

   //--- 3) 80-20's ------------------------------------------------------
   // Buy day: yesterday opened in the TOP band of its range and closed in
   // the BOTTOM band (big down bar). Today price must first trade
   // TriggerPts below yesterday's low; then buy stop back at yesterday's low.
   if(InpUse8020)
     {
      double rng=DH(1)-DL(1);
      if(rng>0)
        {
         double oPos=(DO(1)-DL(1))/rng;
         double cPos=(DC(1)-DL(1))/rng;
         if(oPos>=1.0-InpEE_Band && cPos<=InpEE_Band)   // buy setup
           {
            S[EIGHTY20].longArmed=true;
            S[EIGHTY20].longLevel=DL(1)+Buf();
           }
         if(oPos<=InpEE_Band && cPos>=1.0-InpEE_Band)   // sell setup
           {
            S[EIGHTY20].shortArmed=true;
            S[EIGHTY20].shortLevel=DH(1)-Buf();
           }
        }
     }

   //--- 4) MOMENTUM PINBALL ---------------------------------------------
   // Yesterday's LBR/RSI (RSI(3) of 1-day ROC) below 30 -> today is a buy
   // day: buy breakout of the first-hour high. Above 70 -> sell day.
   if(InpUseMomPin)
     {
      double v=LBR_RSI(1);
      if(v<InpMP_BuyLevel)  mpBias=+1;
      if(v>InpMP_SellLevel) mpBias=-1;
     }

   //--- 5) HOLY GRAIL -----------------------------------------------------
   // ADX(14)>30 and rising. Yesterday touched the 20-EMA during an uptrend
   // (+DI>-DI proxy: price above EMA trend via close>EMA 5 bars ago).
   // Buy stop above yesterday's high; SL at yesterday's low; TP at the
   // swing high made before the pullback.
   if(InpUseGrail)
     {
      double adx1,adx2;
      if(ADXVals(adx1,adx2) && adx1>InpHG_ADXLevel && adx1>adx2)
        {
         double ema1=EMAVal(1);
         double emaOld=EMAVal(6);
         bool upTrend  =(ema1>emaOld);
         bool dnTrend  =(ema1<emaOld);
         bool touchedUp=(DL(1)<=ema1 && DC(1)>=ema1*0.999);
         bool touchedDn=(DH(1)>=ema1 && DC(1)<=ema1*1.001);
         if(upTrend && DL(1)<=ema1)
           {
            S[GRAIL].longArmed=true;
            S[GRAIL].longLevel=DH(1)+Buf();
            S[GRAIL].longSL   =MathMin(DL(1),ema1)-Buf();
            S[GRAIL].longTP   =HHigh(2,InpHG_SwingLookback);
           }
         if(dnTrend && DH(1)>=ema1)
           {
            S[GRAIL].shortArmed=true;
            S[GRAIL].shortLevel=DL(1)-Buf();
            S[GRAIL].shortSL   =MathMax(DH(1),ema1)+Buf();
            S[GRAIL].shortTP   =LLow(2,InpHG_SwingLookback);
           }
        }
     }

   //--- 6) THE ANTI --------------------------------------------------------
   // %D slope = trend. %K pulled against %D for >= MinHookBars and has now
   // hooked back in %D's direction -> enter on break of yesterday's extreme.
   if(InpUseAnti)
     {
      double k1,k2,k3,d1,d2;
      if(StochVals(k1,k2,k3,d1,d2))
        {
         bool dUp=(d1>d2), dDn=(d1<d2);
         bool kPulledDown=(k2<k3);            // %K was falling against up %D
         bool kHookUp    =(k1>k2);
         bool kPulledUp  =(k2>k3);
         bool kHookDn    =(k1<k2);
         if(dUp && kPulledDown && kHookUp)
           {
            S[ANTI].longArmed=true;
            S[ANTI].longLevel=DH(1)+Buf();
            S[ANTI].longSL   =LLow(1,3)-Buf();  // below the pullback lows
           }
         if(dDn && kPulledUp && kHookDn)
           {
            S[ANTI].shortArmed=true;
            S[ANTI].shortLevel=DL(1)-Buf();
            S[ANTI].shortSL   =HHigh(1,3)+Buf();
           }
        }
     }

   //--- 7) ID/NR4 ----------------------------------------------------------
   // Yesterday: inside day AND narrowest range of the last 4 days.
   // Today: bracket with buy stop above / sell stop below yesterday.
   if(InpUseIDNR4)
     {
      double r1=DH(1)-DL(1);
      bool inside=(DH(1)<DH(2) && DL(1)>DL(2));
      bool nr4=(r1<DH(2)-DL(2) && r1<DH(3)-DL(3) && r1<DH(4)-DL(4));
      if(inside && nr4 && r1>0)
        {
         S[IDNR4].longArmed=true;
         S[IDNR4].longLevel =DH(1)+Buf();
         S[IDNR4].longSL    =DL(1)-Buf();
         S[IDNR4].shortArmed=true;
         S[IDNR4].shortLevel=DL(1)-Buf();
         S[IDNR4].shortSL   =DH(1)+Buf();
        }
     }

   //--- 8) WHOOPS (gap fade) -------------------------------------------------
   // Today opened below yesterday's low by >= MinGapPts -> buy stop back at
   // yesterday's low (gap-fill fade). Mirror for gap-up opens.
   if(InpUseWhoops)
     {
      double gapDn=DL(1)-DO(0);
      double gapUp=DO(0)-DH(1);
      if(gapDn>=InpWH_MinGapPts*Pt())
        {
         S[WHOOPS].longArmed=true;
         S[WHOOPS].longLevel=DL(1)+Buf();
         S[WHOOPS].longSL   =DO(0)-MathMax(gapDn*0.5,10*Pt());
        }
      if(gapUp>=InpWH_MinGapPts*Pt())
        {
         S[WHOOPS].shortArmed=true;
         S[WHOOPS].shortLevel=DH(1)-Buf();
         S[WHOOPS].shortSL   =DO(0)+MathMax(gapUp*0.5,10*Pt());
        }
     }

   //--- 9) SMASH DAY ------------------------------------------------------------
   // Regular buy smash: yesterday closed BELOW the prior day's low (trap bar).
   // Hidden buy smash: yesterday closed in the bottom 25% of its range but
   // still above the prior close (hidden accumulation failure).
   // Entry: buy stop above yesterday's high; SL below yesterday's low.
   if(InpUseSmash)
     {
      double rng=DH(1)-DL(1);
      bool buyRegular =(DC(1)<DL(2));
      bool sellRegular=(DC(1)>DH(2));
      bool buyHidden=false, sellHidden=false;
      if(InpSM_UseHidden && rng>0)
        {
         double cPos=(DC(1)-DL(1))/rng;
         buyHidden =(cPos<=InpSM_HiddenBand   && DC(1)>DC(2));
         sellHidden=(cPos>=1.0-InpSM_HiddenBand && DC(1)<DC(2));
        }
      if(buyRegular||buyHidden)
        {
         S[SMASH].longArmed=true;
         S[SMASH].longLevel=DH(1)+Buf();
         S[SMASH].longSL   =DL(1)-Buf();
        }
      if(sellRegular||sellHidden)
        {
         S[SMASH].shortArmed=true;
         S[SMASH].shortLevel=DL(1)-Buf();
         S[SMASH].shortSL   =DH(1)+Buf();
        }
     }
  }

//=================== TICK-LEVEL TRIGGERS ============================
void HandleTickTriggers()
  {
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double todayLow =iLow (_Symbol,PERIOD_D1,0);
   double todayHigh=iHigh(_Symbol,PERIOD_D1,0);

   //--- Turtle Soup: needs price to first violate the old extreme
   if(InpUseTSoup && PositionsOf(TSOUP)==0)
     {
      if(S[TSOUP].longArmed && !S[TSOUP].longTriggered &&
         bid < S[TSOUP].longLevel-Buf()-InpTS_TriggerPts*Pt())
        {
         S[TSOUP].longTriggered=true;
         S[TSOUP].longSL=todayLow-Buf();
         if(OrdersOf(TSOUP)==0)
            PlaceStop(TSOUP,true,S[TSOUP].longLevel,S[TSOUP].longSL,0,true);
        }
      if(S[TSOUP].shortArmed && !S[TSOUP].shortTriggered &&
         bid > S[TSOUP].shortLevel+Buf()+InpTS_TriggerPts*Pt())
        {
         S[TSOUP].shortTriggered=true;
         S[TSOUP].shortSL=todayHigh+Buf();
         if(OrdersOf(TSOUP)==0)
            PlaceStop(TSOUP,false,S[TSOUP].shortLevel,S[TSOUP].shortSL,0,true);
        }
     }

   //--- 80-20's: same "violate first, then snap back" mechanic
   if(InpUse8020 && PositionsOf(EIGHTY20)==0)
     {
      if(S[EIGHTY20].longArmed && !S[EIGHTY20].longTriggered &&
         bid < S[EIGHTY20].longLevel-Buf()-InpEE_TriggerPts*Pt())
        {
         S[EIGHTY20].longTriggered=true;
         S[EIGHTY20].longSL=todayLow-Buf();
         if(OrdersOf(EIGHTY20)==0)
            PlaceStop(EIGHTY20,true,S[EIGHTY20].longLevel,S[EIGHTY20].longSL,0,true);
        }
      if(S[EIGHTY20].shortArmed && !S[EIGHTY20].shortTriggered &&
         bid > S[EIGHTY20].shortLevel+Buf()+InpEE_TriggerPts*Pt())
        {
         S[EIGHTY20].shortTriggered=true;
         S[EIGHTY20].shortSL=todayHigh+Buf();
         if(OrdersOf(EIGHTY20)==0)
            PlaceStop(EIGHTY20,false,S[EIGHTY20].shortLevel,S[EIGHTY20].shortSL,0,true);
        }
     }

   //--- Momentum Pinball: place breakout order once first hour completes
   if(InpUseMomPin && mpBias!=0 && !mpRangeDone &&
      TimeCurrent()>=dayStart+InpMP_FirstHourMins*60)
     {
      mpRangeDone=true;
      int h1Start=iBarShift(_Symbol,PERIOD_H1,dayStart);
      if(h1Start>=1)   // first H1 bar of the day has closed
        {
         double fhH=iHigh(_Symbol,PERIOD_H1,h1Start);
         double fhL=iLow (_Symbol,PERIOD_H1,h1Start);
         if(mpBias>0 && PositionsOf(MOMPIN)==0 && OrdersOf(MOMPIN)==0)
            PlaceStop(MOMPIN,true, fhH+Buf(), fhL-Buf(), 0, true);
         if(mpBias<0 && PositionsOf(MOMPIN)==0 && OrdersOf(MOMPIN)==0)
            PlaceStop(MOMPIN,false,fhL-Buf(), fhH+Buf(), 0, true);
        }
     }
  }

//=================== NEW-DAY ORDER PLACEMENT ========================
void PlaceOpeningOrders()
  {
   // Strategies whose orders can go in right at the daily open
   int ids[5]={TSOUP1,GRAIL,ANTI,IDNR4,SMASH};
   for(int n=0;n<5;n++)
     {
      int id=ids[n];
      if(PositionsOf(id)>0 || OrdersOf(id)>0) continue;
      if(S[id].longArmed)
         PlaceStop(id,true ,S[id].longLevel ,S[id].longSL ,S[id].longTP ,true);
      if(S[id].shortArmed)
         PlaceStop(id,false,S[id].shortLevel,S[id].shortSL,S[id].shortTP,true);
     }
   // Whoops: only valid if the gap exists at the open
   if(InpUseWhoops && PositionsOf(WHOOPS)==0 && OrdersOf(WHOOPS)==0)
     {
      if(S[WHOOPS].longArmed)
         PlaceStop(WHOOPS,true ,S[WHOOPS].longLevel ,S[WHOOPS].longSL ,0,true);
      if(S[WHOOPS].shortArmed)
         PlaceStop(WHOOPS,false,S[WHOOPS].shortLevel,S[WHOOPS].shortSL,0,true);
     }
  }

//=================== POSITION MANAGEMENT ============================
void OCOAndBracketMaintenance()
  {
   // ID/NR4 bracket: if one side filled, cancel the opposite pending
   if(PositionsOf(IDNR4)>0 && OrdersOf(IDNR4)>0) CancelOrdersOf(IDNR4);
  }

int TimeExitDaysOf(int id)
  {
   switch(id)
     {
      case TSOUP:  return InpTS_TimeExitDays;
      case TSOUP1: return InpTS1_TimeExitDays;
      case MOMPIN: return InpMP_TimeExitDays;
      case GRAIL:  return InpHG_TimeExitDays;
      case ANTI:   return InpAN_TimeExitDays;
      case IDNR4:  return InpID_TimeExitDays;
      case SMASH:  return InpSM_TimeExitDays;
     }
   return 0;
  }

bool IsDayTrade(int id)
  {
   if(id==EIGHTY20) return InpEE_DayTrade;
   if(id==WHOOPS)   return InpWH_DayTrade;
   return false;
  }

void ManagePositions()
  {
   double atr=ATRD1();
   MqlDateTime now; TimeToStruct(TimeCurrent(),now);
   bool eod=(now.hour>InpEODHour || (now.hour==InpEODHour && now.min>=InpEODMinute));

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long mg=PositionGetInteger(POSITION_MAGIC);
      if(mg<InpMagicBase || mg>=InpMagicBase+N_STRATS) continue;
      int id=(int)(mg-InpMagicBase);

      long   type =PositionGetInteger(POSITION_TYPE);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   =PositionGetDouble(POSITION_SL);
      double tp   =PositionGetDouble(POSITION_TP);
      double cur  =(type==POSITION_TYPE_BUY?
                    SymbolInfoDouble(_Symbol,SYMBOL_BID):
                    SymbolInfoDouble(_Symbol,SYMBOL_ASK));

      // 1) end-of-day flat for day-trade strategies
      if(IsDayTrade(id) && eod){ trade.PositionClose(tk); continue; }

      // 2) time exit
      int lim=TimeExitDaysOf(id);
      if(lim>0 && BarsInTrade(tk)>=lim){ trade.PositionClose(tk); continue; }

      // 3) breakeven at +1R
      if(InpBreakevenAt1R && sl>0)
        {
         double r=MathAbs(entry-sl);
         if(type==POSITION_TYPE_BUY && cur>=entry+r && sl<entry)
            trade.PositionModify(tk,NormalizeDouble(entry+Buf(),_Digits),tp);
         if(type==POSITION_TYPE_SELL && cur<=entry-r && sl>entry)
            trade.PositionModify(tk,NormalizeDouble(entry-Buf(),_Digits),tp);
        }

      // 4) ATR trail
      if(InpATRTrailMult>0 && atr>0)
        {
         if(type==POSITION_TYPE_BUY)
           {
            double t=NormalizeDouble(cur-InpATRTrailMult*atr,_Digits);
            if(t>sl && t<cur) trade.PositionModify(tk,t,tp);
           }
         else
           {
            double t=NormalizeDouble(cur+InpATRTrailMult*atr,_Digits);
            if((sl==0||t<sl) && t>cur) trade.PositionModify(tk,t,tp);
           }
        }
     }
  }

//=================== DAILY EQUITY STOP ==============================
bool DailyStopHit()
  {
   if(InpDailyLossPct<=0) return false;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(dayStartEq>0 && eq<=dayStartEq*(1.0-InpDailyLossPct/100.0)) return true;
   return false;
  }

void FlattenAll()
  {
   for(int id=0;id<N_STRATS;id++){ CancelOrdersOf(id); ClosePositionsOf(id); }
  }

//=================== MQL5 EVENTS ====================================
int OnInit()
  {
   trade.SetDeviationInPoints(20);
   hATR=iATR(_Symbol,PERIOD_D1,14);
   hADX=iADX(_Symbol,PERIOD_D1,InpHG_ADXPeriod);
   hEMA=iMA (_Symbol,PERIOD_D1,InpHG_EMAPeriod,0,MODE_EMA,PRICE_CLOSE);
   hSTO=iStochastic(_Symbol,PERIOD_D1,InpAN_K,InpAN_D,InpAN_Slow,MODE_SMA,STO_LOWHIGH);
   if(hATR==INVALID_HANDLE||hADX==INVALID_HANDLE||hEMA==INVALID_HANDLE||hSTO==INVALID_HANDLE)
     { Print("Indicator handle failed"); return INIT_FAILED; }
   Print("StreetSmartsEA v1.0 initialised on ",_Symbol);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   IndicatorRelease(hATR); IndicatorRelease(hADX);
   IndicatorRelease(hEMA); IndicatorRelease(hSTO);
  }

void OnTick()
  {
   datetime d1=iTime(_Symbol,PERIOD_D1,0);
   if(d1==0) return;

   if(d1!=lastD1Bar)              // ---- new trading day ----
     {
      lastD1Bar=d1;
      dayStart=d1;
      dayStartEq=AccountInfoDouble(ACCOUNT_EQUITY);
      dayHalted=false;
      for(int id=0;id<N_STRATS;id++) CancelOrdersOf(id);   // clear stale pendings
      ScanDailySetups();
      PlaceOpeningOrders();
     }

   if(dayHalted) return;
   if(DailyStopHit())
     {
      dayHalted=true;
      FlattenAll();
      Print("Daily equity stop hit — flat until next day.");
      return;
     }

   HandleTickTriggers();
   OCOAndBracketMaintenance();
   ManagePositions();
  }
//+------------------------------------------------------------------+