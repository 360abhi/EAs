//+------------------------------------------------------------------+
//|                                                 ConnorsSTS.mq5   |
//|  v1.0 — Clean-room MQL5 implementation of the MECHANICAL systems |
//|  popularized in Connors & Alvarez, "Short Term Trading            |
//|  Strategies That Work" (2008).                                    |
//|                                                                   |
//|  All rules are paraphrased/re-engineered from public knowledge    |
//|  of these classic mean-reversion systems — no book text is        |
//|  reproduced. Verify against your own copy before trusting it.     |
//|                                                                   |
//|  Strategies (own magic number + enable flag each):                |
//|   1 RSI2    2-period RSI pullback (optional scale-in)             |
//|   2 CRSI    Cumulative RSI                                        |
//|   3 DBL7    Double 7's                                            |
//|   4 MDD     Multiple down days (consecutive lower closes)         |
//|   5 EOM     End-of-month pullback (adapted parameterization)      |
//|   6 VIXSTR  VIX stretch long entry (needs a VIX symbol)           |
//|   7 BEAR    Bear-market RSI(2) short (below 200-day MA)           |
//|                                                                   |
//|  Design notes:                                                    |
//|  * These are LONG-biased mean-reversion systems built for stock   |
//|    indices/ETFs. Trade them on index CFDs (US500/SPX500 etc.),    |
//|    not FX pairs, unless you have re-validated the edge.           |
//|  * The originals enter/exit ON THE CLOSE and famously use NO      |
//|    hard stops. This EA evaluates signals near end of day          |
//|    (InpSignalHour/Minute) using the live daily bar, which is the  |
//|    closest MT5 analogue to market-on-close. A wide catastrophic   |
//|    ATR stop is ON by default because prop-firm accounts need one; |
//|    set InpCatStopATR=0 to reproduce the stopless originals.       |
//|                                                                   |
//|  NOT financial advice. Backtest & forward-test before live use.   |
//+------------------------------------------------------------------+
#property copyright "Clean-room implementation"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//=================== GENERAL INPUTS =================================
input group "=== Risk & General ==="
input double InpRiskPercent     = 0.5;     // Risk % of equity per unit (vs cat-stop distance)
input double InpDailyLossPct    = 2.0;     // Daily equity stop % (0 = off)
input int    InpMaxSpreadPoints = 40;      // Max spread (points) to trade
input long   InpMagicBase       = 772700;  // Magic number base
input int    InpSignalHour      = 23;      // Signal/entry evaluation hour (server)
input int    InpSignalMinute    = 30;      // Signal/entry evaluation minute
input double InpCatStopATR      = 3.0;     // Catastrophic stop, x ATR(14,D1) (0 = none, as per book)
input int    InpMaxHoldDays     = 10;      // Global failsafe time exit (0 = off)

input group "=== Trend & Volatility Filters ==="
input int    InpMAFilterPeriod  = 200;     // Long-trend SMA filter period
input int    InpExitMAPeriod    = 5;       // Exit MA period (close above/below)
input bool   InpUseVIXFilter    = false;   // Block longs when VIX 5% BELOW its 10-day MA
input string InpVIXSymbol       = "VIX";   // Broker symbol for volatility index
input int    InpVIX_MAPeriod    = 10;
input double InpVIX_BandPct     = 5.0;     // Stretch band %

input group "=== 1) RSI(2) Pullback ==="
input bool   InpUseRSI2         = true;
input double InpR2_BuyLevel     = 5.0;     // Enter long when RSI(2) below this
input double InpR2_ExitLevel    = 70.0;    // Exit when RSI(2) above this
input bool   InpR2_ExitOn5MA    = true;    // ...or on close above 5-SMA
input bool   InpR2_ScaleIn      = true;    // Add a 2nd unit if RSI(2) drops further
input double InpR2_ScaleLevel   = 2.0;     // 2nd-unit trigger

input group "=== 2) Cumulative RSI ==="
input bool   InpUseCRSI         = true;
input int    InpCR_RSIPeriod    = 2;
input int    InpCR_SumDays      = 2;       // Days to accumulate
input double InpCR_BuyLevel     = 35.0;    // Enter when cumulative below
input double InpCR_ExitLevel    = 65.0;    // Exit when cumulative above

input group "=== 3) Double 7's ==="
input bool   InpUseDbl7         = true;
input int    InpD7_Lookback     = 7;       // N-day closing low entry / closing high exit

input group "=== 4) Multiple Down Days ==="
input bool   InpUseMDD          = true;
input int    InpMD_ConsecDown   = 4;       // Consecutive lower closes to enter
input bool   InpMD_ExitFirstUp  = false;   // Exit on first up close (else 5-SMA/RSI exit)

input group "=== 5) End of Month ==="
input bool   InpUseEOM          = true;
input int    InpEM_WindowDays   = 5;       // Enter within last N calendar days of month
input int    InpEM_PullbackLow  = 3;       // ...on an N-day closing low (pullback)
input int    InpEM_MaxHoldDays  = 5;       // Exit by Nth session of new month at latest

input group "=== 6) VIX Stretch ==="
input bool   InpUseVIXStretch   = false;   // Requires valid InpVIXSymbol
input int    InpVX_ConsecDays   = 3;       // VIX above band for N consecutive days
input double InpVX_ExitRSI      = 65.0;    // Exit when index RSI(2) above

input group "=== 7) Bear Market Short ==="
input bool   InpUseBear         = true;
input double InpBR_SellLevel    = 95.0;    // Short when RSI(2) above this (below 200-SMA)
input double InpBR_ExitLevel    = 30.0;    // Cover when RSI(2) below this

//=================== INTERNALS ======================================
CTrade trade;

#define N_STRATS 7
enum CS_ID { RSI2=0, CRSI=1, DBL7=2, MDD=3, EOM=4, VIXSTR=5, BEAR=6 };
string StratName[N_STRATS]={"RSI2","CRSI","DBL7","MDD","EOM","VIXSTR","BEAR"};

int hRSI2=INVALID_HANDLE, hMA200=INVALID_HANDLE, hMA5=INVALID_HANDLE, hATR=INVALID_HANDLE;
int hVIXMA=INVALID_HANDLE;
bool vixOK=false;

datetime lastSignalDay=0;    // day for which signals were already evaluated
datetime lastD1Bar=0;
double   dayStartEq=0.0;
bool     dayHalted=false;

//=================== PRICE HELPERS ==================================
double DO(int i){ return iOpen (_Symbol,PERIOD_D1,i); }
double DH(int i){ return iHigh (_Symbol,PERIOD_D1,i); }
double DL(int i){ return iLow  (_Symbol,PERIOD_D1,i); }
double DC(int i){ return iClose(_Symbol,PERIOD_D1,i); }

long MagicOf(int id){ return InpMagicBase+id; }

bool SpreadOK(){ return SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)<=InpMaxSpreadPoints; }

double Ind1(int handle,int shift)
  {
   double b[1];
   if(CopyBuffer(handle,0,shift,1,b)!=1) return EMPTY_VALUE;
   return b[0];
  }

// RSI(2) using the LIVE current bar as "today's close" when called with shift 0
double RSI2Val(int shift){ return Ind1(hRSI2,shift); }
double MA200Val(int shift){ return Ind1(hMA200,shift); }
double MA5Val(int shift){ return Ind1(hMA5,shift); }
double ATRD1(){ return Ind1(hATR,1); }

double CumRSI(int days)
  {
   double s=0;
   for(int i=0;i<days;i++)
     {
      double v=RSI2Val(i);
      if(v==EMPTY_VALUE) return EMPTY_VALUE;
      s+=v;
     }
   return s;
  }

// Lowest/highest CLOSE over `count` bars starting at `from`
double LClose(int from,int count)
  {
   double m=DBL_MAX;
   for(int i=from;i<from+count;i++) m=MathMin(m,DC(i));
   return m;
  }
double HClose(int from,int count)
  {
   double m=-DBL_MAX;
   for(int i=from;i<from+count;i++) m=MathMax(m,DC(i));
   return m;
  }

//=================== VIX HELPERS ====================================
double VIXClose(int shift){ return iClose(InpVIXSymbol,PERIOD_D1,shift); }
double VIXMA(int shift){ return (vixOK? Ind1(hVIXMA,shift):EMPTY_VALUE); }

// true when VIX is >= band% ABOVE its MA on bar `shift`
bool VIXAboveBand(int shift)
  {
   if(!vixOK) return false;
   double v=VIXClose(shift), m=VIXMA(shift);
   if(v<=0||m<=0||m==EMPTY_VALUE) return false;
   return (v>=m*(1.0+InpVIX_BandPct/100.0));
  }
// true when VIX is <= band% BELOW its MA (complacency — block longs)
bool VIXBelowBand(int shift)
  {
   if(!vixOK) return false;
   double v=VIXClose(shift), m=VIXMA(shift);
   if(v<=0||m<=0||m==EMPTY_VALUE) return false;
   return (v<=m*(1.0-InpVIX_BandPct/100.0));
  }
bool LongsAllowedByVIX()
  {
   if(!InpUseVIXFilter||!vixOK) return true;
   return !VIXBelowBand(0);
  }

//=================== POSITION / ORDER UTILS =========================
int UnitsOf(int id)
  {
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==MagicOf(id)) n++;
     }
   return n;
  }

void CloseAllOf(int id)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==MagicOf(id))
         trade.PositionClose(tk);
     }
  }

int OldestBarsInTrade(int id)
  {
   datetime oldest=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==MagicOf(id))
        {
         datetime t=(datetime)PositionGetInteger(POSITION_TIME);
         if(oldest==0||t<oldest) oldest=t;
        }
     }
   if(oldest==0) return -1;
   return iBarShift(_Symbol,PERIOD_D1,oldest);
  }

double LotsForRisk(double riskDistance)
  {
   if(riskDistance<=0) return 0.0;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double riskCash=eq*InpRiskPercent/100.0;
   double tickVal =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickVal<=0||tickSize<=0) return 0.0;
   double lossPerLot=riskDistance/tickSize*tickVal;
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

bool Enter(int id,bool isLong,string tag)
  {
   if(!SpreadOK()) return false;
   double atr=ATRD1();
   // Sizing risk proxy: catastrophic stop distance, or 3x ATR when stopless
   double riskDist=(InpCatStopATR>0? InpCatStopATR*atr : 3.0*atr);
   double lots=LotsForRisk(riskDist);
   if(lots<=0) return false;
   trade.SetExpertMagicNumber(MagicOf(id));
   double sl=0;
   if(InpCatStopATR>0 && atr>0)
     {
      double px=(isLong? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                       : SymbolInfoDouble(_Symbol,SYMBOL_BID));
      sl=NormalizeDouble(isLong? px-InpCatStopATR*atr : px+InpCatStopATR*atr,_Digits);
     }
   bool ok=(isLong? trade.Buy (lots,_Symbol,0,sl,0,tag)
                  : trade.Sell(lots,_Symbol,0,sl,0,tag));
   if(ok) PrintFormat("[%s] %s %s lots %.2f",StratName[id],(isLong?"BUY":"SELL"),tag,lots);
   return ok;
  }

//=================== SIGNAL EVALUATION (near daily close) ===========
// All values use the LIVE bar 0 as "today", matching on-close execution.
void EvaluateSignals()
  {
   double close0 =DC(0);
   double ma200  =MA200Val(0);
   double ma5    =MA5Val(0);
   double rsi2   =RSI2Val(0);
   if(ma200==EMPTY_VALUE||ma5==EMPTY_VALUE||rsi2==EMPTY_VALUE) return;
   bool above200=(close0>ma200);
   bool below200=(close0<ma200);
   bool vixOKLong=LongsAllowedByVIX();

   //----- EXITS first (evaluated on the same close) -----------------

   // RSI2 exit: RSI(2) above exit level, or close above 5-SMA
   if(UnitsOf(RSI2)>0)
     {
      bool ex=(rsi2>InpR2_ExitLevel) || (InpR2_ExitOn5MA && close0>ma5);
      if(ex) CloseAllOf(RSI2);
     }
   // CRSI exit
   if(UnitsOf(CRSI)>0)
     {
      double cs=CumRSI(InpCR_SumDays);
      if(cs!=EMPTY_VALUE && cs>InpCR_ExitLevel) CloseAllOf(CRSI);
     }
   // Double 7's exit: today's close is the highest close of the last N days
   if(UnitsOf(DBL7)>0)
     {
      if(close0>=HClose(0,InpD7_Lookback)) CloseAllOf(DBL7);
     }
   // MDD exit
   if(UnitsOf(MDD)>0)
     {
      bool ex=(InpMD_ExitFirstUp? (close0>DC(1))
                                : (close0>ma5 || rsi2>InpR2_ExitLevel));
      if(ex) CloseAllOf(MDD);
     }
   // EOM exit: close above 5-SMA, or Nth session of the new month
   if(UnitsOf(EOM)>0)
     {
      MqlDateTime t; TimeToStruct(iTime(_Symbol,PERIOD_D1,0),t);
      int barsHeld=OldestBarsInTrade(EOM);
      bool newMonthTimeout=false;
      // count sessions since month start
      MqlDateTime e; TimeToStruct((datetime)PositionGetInteger(POSITION_TIME),e);
      if(barsHeld>=0 && t.day<15 && barsHeld>=1)   // we are in the new month
        {
         // exit at latest after InpEM_MaxHoldDays sessions in the new month:
         // approximate with total bars held >= window + max hold
         if(barsHeld>=InpEM_MaxHoldDays) newMonthTimeout=true;
        }
      if(close0>ma5 || newMonthTimeout) CloseAllOf(EOM);
     }
   // VIX stretch exit
   if(UnitsOf(VIXSTR)>0)
     {
      if(rsi2>InpVX_ExitRSI || close0>ma5) CloseAllOf(VIXSTR);
     }
   // Bear short cover
   if(UnitsOf(BEAR)>0)
     {
      if(rsi2<InpBR_ExitLevel || close0<ma5) CloseAllOf(BEAR);
     }

   //----- Global failsafe time exit ---------------------------------
   if(InpMaxHoldDays>0)
      for(int id=0;id<N_STRATS;id++)
         if(UnitsOf(id)>0 && OldestBarsInTrade(id)>=InpMaxHoldDays)
            CloseAllOf(id);

   //----- ENTRIES ----------------------------------------------------

   // 1) RSI(2) pullback
   if(InpUseRSI2 && above200 && vixOKLong)
     {
      int u=UnitsOf(RSI2);
      if(u==0 && rsi2<InpR2_BuyLevel)
         Enter(RSI2,true,"RSI2 u1");
      else if(u==1 && InpR2_ScaleIn && rsi2<InpR2_ScaleLevel)
         Enter(RSI2,true,"RSI2 u2");
     }

   // 2) Cumulative RSI
   if(InpUseCRSI && above200 && vixOKLong && UnitsOf(CRSI)==0)
     {
      double cs=CumRSI(InpCR_SumDays);
      if(cs!=EMPTY_VALUE && cs<InpCR_BuyLevel)
         Enter(CRSI,true,"CRSI");
     }

   // 3) Double 7's: today's close is the lowest close of the last N days
   if(InpUseDbl7 && above200 && vixOKLong && UnitsOf(DBL7)==0)
     {
      if(close0<=LClose(0,InpD7_Lookback))
         Enter(DBL7,true,"DBL7");
     }

   // 4) Multiple down days: N consecutive lower closes
   if(InpUseMDD && above200 && vixOKLong && UnitsOf(MDD)==0)
     {
      bool ok=true;
      for(int i=0;i<InpMD_ConsecDown;i++)
         if(!(DC(i)<DC(i+1))){ ok=false; break; }
      if(ok) Enter(MDD,true,"MDD");
     }

   // 5) End of month pullback (adapted): within the last N calendar days
   //    of the month, above 200-SMA, on an N-day closing low
   if(InpUseEOM && above200 && vixOKLong && UnitsOf(EOM)==0)
     {
      MqlDateTime t; TimeToStruct(iTime(_Symbol,PERIOD_D1,0),t);
      int dim=31;
      switch(t.mon)
        {
         case 4: case 6: case 9: case 11: dim=30; break;
         case 2: dim=(t.year%4==0 && (t.year%100!=0||t.year%400==0))?29:28; break;
        }
      bool window=(t.day>dim-InpEM_WindowDays);
      bool pullback=(close0<=LClose(0,InpEM_PullbackLow));
      if(window && pullback) Enter(EOM,true,"EOM");
     }

   // 6) VIX stretch: VIX >= band above its 10-day MA for N consecutive days
   if(InpUseVIXStretch && vixOK && above200 && UnitsOf(VIXSTR)==0)
     {
      bool ok=true;
      for(int i=0;i<InpVX_ConsecDays;i++)
         if(!VIXAboveBand(i)){ ok=false; break; }
      if(ok) Enter(VIXSTR,true,"VIXSTR");
     }

   // 7) Bear market short: RSI(2) very overbought below the 200-SMA
   if(InpUseBear && below200 && UnitsOf(BEAR)==0)
     {
      if(rsi2>InpBR_SellLevel) Enter(BEAR,false,"BEAR");
     }
  }

//=================== DAILY EQUITY STOP ==============================
bool DailyStopHit()
  {
   if(InpDailyLossPct<=0) return false;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   return (dayStartEq>0 && eq<=dayStartEq*(1.0-InpDailyLossPct/100.0));
  }

void FlattenAll(){ for(int id=0;id<N_STRATS;id++) CloseAllOf(id); }

//=================== MQL5 EVENTS ====================================
int OnInit()
  {
   trade.SetDeviationInPoints(30);
   hRSI2 =iRSI(_Symbol,PERIOD_D1,InpCR_RSIPeriod,PRICE_CLOSE);   // period 2 default
   hMA200=iMA (_Symbol,PERIOD_D1,InpMAFilterPeriod,0,MODE_SMA,PRICE_CLOSE);
   hMA5  =iMA (_Symbol,PERIOD_D1,InpExitMAPeriod ,0,MODE_SMA,PRICE_CLOSE);
   hATR  =iATR(_Symbol,PERIOD_D1,14);
   if(hRSI2==INVALID_HANDLE||hMA200==INVALID_HANDLE||hMA5==INVALID_HANDLE||hATR==INVALID_HANDLE)
     { Print("Indicator handle failed"); return INIT_FAILED; }

   vixOK=false;
   if((InpUseVIXFilter||InpUseVIXStretch) && InpVIXSymbol!="")
     {
      if(SymbolSelect(InpVIXSymbol,true))
        {
         hVIXMA=iMA(InpVIXSymbol,PERIOD_D1,InpVIX_MAPeriod,0,MODE_SMA,PRICE_CLOSE);
         vixOK=(hVIXMA!=INVALID_HANDLE);
        }
      if(!vixOK) Print("WARNING: VIX symbol '",InpVIXSymbol,"' unavailable — VIX features disabled.");
     }
   Print("ConnorsSTS v1.0 initialised on ",_Symbol,
         " | signal time ",InpSignalHour,":",InpSignalMinute,
         " | cat-stop ",InpCatStopATR,"x ATR");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   IndicatorRelease(hRSI2); IndicatorRelease(hMA200);
   IndicatorRelease(hMA5);  IndicatorRelease(hATR);
   if(hVIXMA!=INVALID_HANDLE) IndicatorRelease(hVIXMA);
  }

void OnTick()
  {
   datetime d1=iTime(_Symbol,PERIOD_D1,0);
   if(d1==0) return;

   if(d1!=lastD1Bar)          // new trading day housekeeping
     {
      lastD1Bar=d1;
      dayStartEq=AccountInfoDouble(ACCOUNT_EQUITY);
      dayHalted=false;
     }

   if(dayHalted) return;
   if(DailyStopHit())
     {
      dayHalted=true;
      FlattenAll();
      Print("Daily equity stop hit — flat until next day.");
      return;
     }

   // Evaluate once per day at/after the signal time, using live bar values
   MqlDateTime now; TimeToStruct(TimeCurrent(),now);
   bool atSignalTime=(now.hour>InpSignalHour ||
                     (now.hour==InpSignalHour && now.min>=InpSignalMinute));
   if(atSignalTime && lastSignalDay!=d1)
     {
      lastSignalDay=d1;
      EvaluateSignals();
     }
  }
//+------------------------------------------------------------------+