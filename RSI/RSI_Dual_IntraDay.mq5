#property copyright "Copyright 2025, Built for User"
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade/Trade.mqh>

//====================================================================
// EA INPUTS
//====================================================================

// --- Timeframes ---
input ENUM_TIMEFRAMES Entry_Timeframe        = PERIOD_M5;
input ENUM_TIMEFRAMES Regime_Timeframe       = PERIOD_M15;

// --- RSI Regime Parameters ---
input int             Regime_RSI_Period      = 14;

input double          Long_Regime_Level      = 50.0;
input double          Short_Regime_Level     = 50.0;

input double          Long_Regime_Kill       = 40.0;
input double          Short_Regime_Kill      = 60.0;

// --- Fast RSI Pullback Parameters ---
input int             Fast_RSI_Period        = 3;

input double          RSI_Buy_Threshold      = 20.0;
input double          RSI_Sell_Threshold     = 80.0;

// --- ATR Parameters ---
input int             ATR_Period             = 14;

// Pullback cannot be larger than this ATR amount
input double          Max_Pullback_ATR       = 1.50;

// Entry-to-SL distance cannot exceed this ATR amount
input double          Max_Stop_ATR           = 1.20;

// Number of M5 bars used to identify pullback starting point
input int             Pullback_Lookback      = 12;

// --- Structure / Swing Parameters ---
input int             Swing_Left_Bars        = 2;
input int             Swing_Right_Bars       = 2;

input int             Swing_Search_Bars      = 100;

// --- Stop Loss Parameters ---
// IMPORTANT:
// This is actual PRICE distance.
//
// For US100:
// 1.0 means 1 Nasdaq point.
input double          Stop_Buffer_Price      = 1.0;

// Stop must be at least this many times current spread
input double          Min_Stop_Spread_Multiple = 4.0;

// --- Target Parameters ---
input double          Reward_Risk            = 2.0;

// --- Time Stop Parameters ---
input bool            Use_Time_Stop          = true;

input int             Max_Candles            = 8;

// Trade must achieve this R before Max_Candles
input double          Required_R             = 1.0;

// --- VWAP Exit ---
input bool            Use_VWAP_Exit          = true;

// --- Session Settings (New York Time) ---

// VWAP Starts at NY Market Open
input int             VWAP_Start_Hour        = 9;
input int             VWAP_Start_Minute      = 30;

// Primary Session
input int             Morning_Start_Hour     = 9;
input int             Morning_Start_Minute   = 45;

input int             Morning_End_Hour       = 11;
input int             Morning_End_Minute     = 30;

// Secondary Session
input bool            Use_Afternoon_Session  = true;

input int             Afternoon_Start_Hour   = 13;
input int             Afternoon_Start_Minute = 30;

input int             Afternoon_End_Hour     = 14;
input int             Afternoon_End_Minute   = 45;

// Hard Flat
input int             Flat_Hour              = 15;
input int             Flat_Minute            = 55;

// NY Time = Broker Server Time + this Offset
//
// Example:
// Broker UTC+3
// New York UTC-4
//
// Offset = -7
input int             NY_Offset_From_Server  = -7;

// --- Trade Frequency / Risk Limits ---
input int             Max_Trades_Per_Day     = 3;

input int             Max_Losses_Per_Day     = 2;

input int             Max_Same_Side_Losses   = 2;

// --- Equity Loss Limits ---
input bool            Use_Daily_Loss_Limit   = true;
input double          Daily_Loss_Percent     = 1.50;

input bool            Use_Weekly_Loss_Limit  = true;
input double          Weekly_Loss_Percent    = 3.00;

// --- Trade Settings ---
input int             MagicNumber            = 330003;

input bool            Use_Risk_Percent       = true;

input double          Risk_Percent           = 0.25;

input double          LotSize                = 0.10;

input int             SlippagePoints         = 5;

input bool            Allow_Buys             = true;
input bool            Allow_Sells            = true;


//====================================================================
// GLOBAL VARIABLES
//====================================================================

CTrade trade;

datetime lastEntryBarTime;
datetime lastRegimeBarTime;


// --- Regime State ---

bool longRegimeKilled  = false;
bool shortRegimeKilled = false;

// Used to enforce:
// Afternoon trades only if morning regime remained intact
bool longRegimeBrokenToday  = false;
bool shortRegimeBrokenToday = false;


// --- Pullback Setup State ---

bool longSetupActive  = false;
bool shortSetupActive = false;


// LONG Setup

double longPullbackLow  = 0.0;
double longPullbackHigh = 0.0;

double longStructureLow = 0.0;


// SHORT Setup

double shortPullbackHigh = 0.0;
double shortPullbackLow  = 0.0;

double shortStructureHigh = 0.0;


// --- Current Trade Tracking ---

double currentEntryPrice  = 0.0;
double currentInitialRisk = 0.0;

datetime currentTradeOpenTime = 0;

bool reachedRequiredR = false;


// --- Daily Statistics ---

int tradesToday = 0;
int lossesToday = 0;

int consecutiveLongLosses  = 0;
int consecutiveShortLosses = 0;


// --- Equity Tracking ---

double dayStartEquity  = 0.0;
double weekStartEquity = 0.0;

int currentDay = -1;

datetime currentWeek = 0;


//====================================================================
// INDICATOR HANDLES
//====================================================================

int h_FastRSI;
int h_RegimeRSI;
int h_ATR;


//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // --- 1. Fast M5 RSI Handle ---
   h_FastRSI =
      iRSI(
         _Symbol,
         Entry_Timeframe,
         Fast_RSI_Period,
         PRICE_CLOSE
      );


   // --- 2. M15 Regime RSI Handle ---
   h_RegimeRSI =
      iRSI(
         _Symbol,
         Regime_Timeframe,
         Regime_RSI_Period,
         PRICE_CLOSE
      );


   // --- 3. M15 ATR Handle ---
   h_ATR =
      iATR(
         _Symbol,
         Regime_Timeframe,
         ATR_Period
      );


   if(h_FastRSI == INVALID_HANDLE ||
      h_RegimeRSI == INVALID_HANDLE ||
      h_ATR == INVALID_HANDLE)
     {
      Print("Error creating indicator handles");

      return(INIT_FAILED);
     }


   // --- 4. Trade Settings ---

   trade.SetExpertMagicNumber(
      MagicNumber
   );

   trade.SetDeviationInPoints(
      SlippagePoints
   );

   trade.SetAsyncMode(false);

   trade.SetTypeFillingBySymbol(
      _Symbol
   );


   // --- 5. Initialize Bar Times ---

   lastEntryBarTime =
      iTime(
         _Symbol,
         Entry_Timeframe,
         0
      );

   lastRegimeBarTime =
      iTime(
         _Symbol,
         Regime_Timeframe,
         0
      );


   // --- 6. Initialize Equity ---

   dayStartEquity =
      AccountInfoDouble(
         ACCOUNT_EQUITY
      );

   weekStartEquity =
      dayStartEquity;


   CheckNewDay();


   return(INIT_SUCCEEDED);
  }


//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(h_FastRSI);

   IndicatorRelease(h_RegimeRSI);

   IndicatorRelease(h_ATR);
  }


//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // ==============================================================
   // 1. CHECK NEW DAY / WEEK
   // ==============================================================

   CheckNewDay();


   // ==============================================================
   // 2. HARD END-OF-DAY EXIT
   // ==============================================================

   if(IsTimeReached(
         Flat_Hour,
         Flat_Minute
      ))
     {
      CloseMyPosition();

      longSetupActive  = false;
      shortSetupActive = false;

      return;
     }


   // ==============================================================
   // 3. TRACK +1R INTRABAR
   //
   // We track this every tick because price could touch +1R
   // and return before the M5 candle closes.
   // ==============================================================

   if(DoesMyPositionExist())
     {
      TrackTradeProgress();
     }


   // ==============================================================
   // 4. UPDATE M15 REGIME
   // ==============================================================

   if(isNewRegimeBar())
     {
      UpdateRegimeState();
     }


   // ==============================================================
   // 5. ALL SIGNAL / EXIT LOGIC RUNS ON NEW M5 BAR
   // ==============================================================

   if(!isNewBar())
      return;


   // ==============================================================
   // 6. CHECK EXISTING TRADE EXITS FIRST
   // ==============================================================

   bool hadPosition =
      DoesMyPositionExist();


   if(hadPosition)
     {
      CheckExits();

      // Do not exit and immediately re-enter on same bar.
      return;
     }


   // ==============================================================
   // 7. CHECK IF ENTRY SESSION IS ACTIVE
   // ==============================================================

   if(!IsEntrySession())
     {
      longSetupActive  = false;
      shortSetupActive = false;

      return;
     }


   // ==============================================================
   // 8. CHECK DAILY / WEEKLY RISK LIMITS
   // ==============================================================

   if(!TradingAllowed())
      return;


   // ==============================================================
   // 9. CHECK ENTRIES
   // ==============================================================

   CheckEntries();
  }


//+------------------------------------------------------------------+
//| Helper: Check Entries                                            |
//+------------------------------------------------------------------+
void CheckEntries()
  {
   if(DoesMyPositionExist())
      return;


   // ==============================================================
   // 1. FIRST CHECK WHETHER AN EXISTING PULLBACK CAN TRIGGER
   // ==============================================================

   if(longSetupActive)
     {
      CheckLongTrigger();

      if(DoesMyPositionExist())
         return;
     }


   if(shortSetupActive)
     {
      CheckShortTrigger();

      if(DoesMyPositionExist())
         return;
     }


   // ==============================================================
   // 2. LOOK FOR NEW RSI PULLBACK SETUPS
   // ==============================================================

   CheckLongSetup();

   CheckShortSetup();
  }


//+------------------------------------------------------------------+
//| Helper: Check Long Pullback Setup                                |
//+------------------------------------------------------------------+
void CheckLongSetup()
  {
   if(!Allow_Buys)
      return;


   if(consecutiveLongLosses >= Max_Same_Side_Losses)
      return;


   // --- Get Latest Closed M5 RSI ---

   double rsi =
      GetIndicatorValue(
         h_FastRSI,
         1
      );


   if(rsi < 0.0)
      return;


   // ==============================================================
   // S1:
   // RSI(3) closes below Buy Threshold
   // ==============================================================

   if(rsi >= RSI_Buy_Threshold)
      return;


   // ==============================================================
   // Check Trend Regime
   // ==============================================================

   if(!IsLongRegimeValid())
      return;


   // ==============================================================
   // If Setup Already Active:
   // Keep Updating Pullback Low
   // ==============================================================

   if(longSetupActive)
     {
      double currentLow =
         iLow(
            _Symbol,
            Entry_Timeframe,
            1
         );


      if(currentLow < longPullbackLow)
         longPullbackLow =
            currentLow;


      return;
     }


   // ==============================================================
   // S2:
   // Find Last Major Higher Low
   // ==============================================================

   longStructureLow =
      FindLastHigherLow();


   // No objective Higher-Low found
   if(longStructureLow <= 0.0)
      return;


   // ==============================================================
   // Store Pullback Details
   // ==============================================================

   longPullbackLow =
      iLow(
         _Symbol,
         Entry_Timeframe,
         1
      );


   // Approximate beginning/top of pullback
   longPullbackHigh =
      GetHighestHigh(
         Pullback_Lookback,
         2
      );


   if(longPullbackHigh <= longPullbackLow)
      return;


   longSetupActive = true;


   Print(
      "LONG Setup Active",
      " | RSI = ",
      rsi,
      " | Structure Low = ",
      longStructureLow,
      " | Pullback Low = ",
      longPullbackLow
   );
  }


//+------------------------------------------------------------------+
//| Helper: Check Short Pullback Setup                               |
//+------------------------------------------------------------------+
void CheckShortSetup()
  {
   if(!Allow_Sells)
      return;


   if(consecutiveShortLosses >= Max_Same_Side_Losses)
      return;


   // --- Latest Closed M5 RSI ---

   double rsi =
      GetIndicatorValue(
         h_FastRSI,
         1
      );


   if(rsi < 0.0)
      return;


   // ==============================================================
   // S1 SHORT:
   // RSI(3) closes above Sell Threshold
   // ==============================================================

   if(rsi <= RSI_Sell_Threshold)
      return;


   // ==============================================================
   // Check Short Trend Regime
   // ==============================================================

   if(!IsShortRegimeValid())
      return;


   // ==============================================================
   // Existing Setup:
   // Keep Updating Pullback High
   // ==============================================================

   if(shortSetupActive)
     {
      double currentHigh =
         iHigh(
            _Symbol,
            Entry_Timeframe,
            1
         );


      if(currentHigh > shortPullbackHigh)
         shortPullbackHigh =
            currentHigh;


      return;
     }


   // ==============================================================
   // Find Last Major Lower High
   // ==============================================================

   shortStructureHigh =
      FindLastLowerHigh();


   if(shortStructureHigh <= 0.0)
      return;


   // ==============================================================
   // Store Pullback Details
   // ==============================================================

   shortPullbackHigh =
      iHigh(
         _Symbol,
         Entry_Timeframe,
         1
      );


   shortPullbackLow =
      GetLowestLow(
         Pullback_Lookback,
         2
      );


   if(shortPullbackHigh <= shortPullbackLow)
      return;


   shortSetupActive = true;


   Print(
      "SHORT Setup Active",
      " | RSI = ",
      rsi,
      " | Structure High = ",
      shortStructureHigh,
      " | Pullback High = ",
      shortPullbackHigh
   );
  }


//+------------------------------------------------------------------+
//| Helper: Check Long Trigger                                       |
//+------------------------------------------------------------------+
void CheckLongTrigger()
  {
   if(!Allow_Buys)
     {
      longSetupActive = false;
      return;
     }


   if(consecutiveLongLosses >= Max_Same_Side_Losses)
     {
      longSetupActive = false;
      return;
     }


   // ==============================================================
   // 1. Regime Must Still Be Valid
   // ==============================================================

   if(!IsLongRegimeValid())
     {
      longSetupActive = false;
      return;
     }


   // ==============================================================
   // 2. Update Pullback Low
   // ==============================================================

   double currentLow =
      iLow(
         _Symbol,
         Entry_Timeframe,
         1
      );


   if(currentLow < longPullbackLow)
      longPullbackLow =
         currentLow;


   // ==============================================================
   // 3. Structure Must Hold
   // ==============================================================

   if(longPullbackLow <= longStructureLow)
     {
      Print("LONG Cancelled: Structure Broken");

      longSetupActive = false;
      return;
     }


   // ==============================================================
   // 4. RSI Must Cross Back ABOVE Threshold
   // ==============================================================

   double rsi1 =
      GetIndicatorValue(
         h_FastRSI,
         1
      );


   double rsi2 =
      GetIndicatorValue(
         h_FastRSI,
         2
      );


   bool rsiCrossUp =
      (
         rsi2 <= RSI_Buy_Threshold
         &&
         rsi1 > RSI_Buy_Threshold
      );


   if(!rsiCrossUp)
      return;


   // ==============================================================
   // 5. Price Confirmation
   //
   // Signal Candle Close must be above Previous Candle High
   // ==============================================================

   double signalClose =
      iClose(
         _Symbol,
         Entry_Timeframe,
         1
      );


   double previousHigh =
      iHigh(
         _Symbol,
         Entry_Timeframe,
         2
      );


   if(signalClose <= previousHigh)
     {
      Print(
         "LONG Recross but Price Confirmation Failed"
      );

      return;
     }


   // ==============================================================
   // 6. Get M15 ATR
   // ==============================================================

   double atr =
      GetIndicatorValue(
         h_ATR,
         1
      );


   if(atr <= 0.0)
      return;


   // ==============================================================
   // 7. CLIMAX VETO
   //
   // Pullback > 1.5 ATR = Repricing, not normal pullback
   // ==============================================================

   double pullbackDistance =
      longPullbackHigh -
      longPullbackLow;


   if(pullbackDistance >
      Max_Pullback_ATR * atr)
     {
      Print(
         "LONG Cancelled: Pullback Too Large"
      );

      longSetupActive = false;

      return;
     }


   // ==============================================================
   // 8. Calculate SL
   // ==============================================================

   double ask =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_ASK
      );


   double bid =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_BID
      );


   double spread =
      ask - bid;


   double stopLoss =
      longPullbackLow -
      Stop_Buffer_Price;


   stopLoss =
      NormalizePrice(
         stopLoss
      );


   double risk =
      ask -
      stopLoss;


   if(risk <= 0.0)
     {
      longSetupActive = false;
      return;
     }


   // ==============================================================
   // 9. Stop Cannot Be Too Large
   // ==============================================================

   if(risk >
      Max_Stop_ATR * atr)
     {
      Print(
         "LONG Cancelled: Stop > Maximum ATR"
      );

      longSetupActive = false;

      return;
     }


   // ==============================================================
   // 10. Stop Cannot Be Too Small Relative To Spread
   // ==============================================================

   if(risk <
      Min_Stop_Spread_Multiple *
      spread)
     {
      Print(
         "LONG Cancelled: Stop Too Small vs Spread"
      );

      longSetupActive = false;

      return;
     }


   // ==============================================================
   // 11. Calculate TP
   // ==============================================================

   double takeProfit =
      ask +
      (
         risk *
         Reward_Risk
      );


   takeProfit =
      NormalizePrice(
         takeProfit
      );


   // ==============================================================
   // 12. Calculate Lot Size
   // ==============================================================

   double lots =
      CalculateLotSize(
         ask,
         stopLoss
      );


   if(lots <= 0.0)
     {
      longSetupActive = false;
      return;
     }


   // ==============================================================
   // 13. BUY
   // ==============================================================

   bool placed =
      trade.Buy(
         lots,
         _Symbol,
         0.0,
         stopLoss,
         takeProfit,
         "RSI-DUAL Buy"
      );


   if(placed)
     {
      tradesToday++;

      StoreNewTradeInformation();

      Print(
         "RSI-DUAL BUY",
         " | Lots = ",
         lots,
         " | SL = ",
         stopLoss,
         " | TP = ",
         takeProfit
      );
     }
   else
     {
      Print(
         "BUY Failed: ",
         trade.ResultRetcodeDescription()
      );
     }


   longSetupActive = false;
  }


//+------------------------------------------------------------------+
//| Helper: Check Short Trigger                                      |
//+------------------------------------------------------------------+
void CheckShortTrigger()
  {
   if(!Allow_Sells)
     {
      shortSetupActive = false;
      return;
     }


   if(consecutiveShortLosses >= Max_Same_Side_Losses)
     {
      shortSetupActive = false;
      return;
     }


   // ==============================================================
   // 1. Regime Must Still Be Valid
   // ==============================================================

   if(!IsShortRegimeValid())
     {
      shortSetupActive = false;
      return;
     }


   // ==============================================================
   // 2. Update Pullback High
   // ==============================================================

   double currentHigh =
      iHigh(
         _Symbol,
         Entry_Timeframe,
         1
      );


   if(currentHigh > shortPullbackHigh)
      shortPullbackHigh =
         currentHigh;


   // ==============================================================
   // 3. Structure Must Hold
   // ==============================================================

   if(shortPullbackHigh >= shortStructureHigh)
     {
      Print("SHORT Cancelled: Structure Broken");

      shortSetupActive = false;
      return;
     }


   // ==============================================================
   // 4. RSI Must Cross Back BELOW Threshold
   // ==============================================================

   double rsi1 =
      GetIndicatorValue(
         h_FastRSI,
         1
      );


   double rsi2 =
      GetIndicatorValue(
         h_FastRSI,
         2
      );


   bool rsiCrossDown =
      (
         rsi2 >= RSI_Sell_Threshold
         &&
         rsi1 < RSI_Sell_Threshold
      );


   if(!rsiCrossDown)
      return;


   // ==============================================================
   // 5. Price Confirmation
   //
   // Signal candle closes below Previous Candle Low
   // ==============================================================

   double signalClose =
      iClose(
         _Symbol,
         Entry_Timeframe,
         1
      );


   double previousLow =
      iLow(
         _Symbol,
         Entry_Timeframe,
         2
      );


   if(signalClose >= previousLow)
     {
      Print(
         "SHORT Recross but Price Confirmation Failed"
      );

      return;
     }


   // ==============================================================
   // 6. Get M15 ATR
   // ==============================================================

   double atr =
      GetIndicatorValue(
         h_ATR,
         1
      );


   if(atr <= 0.0)
      return;


   // ==============================================================
   // 7. CLIMAX VETO
   // ==============================================================

   double pullbackDistance =
      shortPullbackHigh -
      shortPullbackLow;


   if(pullbackDistance >
      Max_Pullback_ATR * atr)
     {
      Print(
         "SHORT Cancelled: Pullback Too Large"
      );

      shortSetupActive = false;

      return;
     }


   // ==============================================================
   // 8. Calculate SL
   // ==============================================================

   double ask =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_ASK
      );


   double bid =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_BID
      );


   double spread =
      ask - bid;


   double stopLoss =
      shortPullbackHigh +
      Stop_Buffer_Price;


   stopLoss =
      NormalizePrice(
         stopLoss
      );


   double risk =
      stopLoss -
      bid;


   if(risk <= 0.0)
     {
      shortSetupActive = false;
      return;
     }


   // ==============================================================
   // 9. Maximum Stop Filter
   // ==============================================================

   if(risk >
      Max_Stop_ATR * atr)
     {
      Print(
         "SHORT Cancelled: Stop > Maximum ATR"
      );

      shortSetupActive = false;

      return;
     }


   // ==============================================================
   // 10. Minimum Stop vs Spread
   // ==============================================================

   if(risk <
      Min_Stop_Spread_Multiple *
      spread)
     {
      Print(
         "SHORT Cancelled: Stop Too Small vs Spread"
      );

      shortSetupActive = false;

      return;
     }


   // ==============================================================
   // 11. Calculate TP
   // ==============================================================

   double takeProfit =
      bid -
      (
         risk *
         Reward_Risk
      );


   takeProfit =
      NormalizePrice(
         takeProfit
      );


   // ==============================================================
   // 12. Calculate Lot Size
   // ==============================================================

   double lots =
      CalculateLotSize(
         bid,
         stopLoss
      );


   if(lots <= 0.0)
     {
      shortSetupActive = false;
      return;
     }


   // ==============================================================
   // 13. SELL
   // ==============================================================

   bool placed =
      trade.Sell(
         lots,
         _Symbol,
         0.0,
         stopLoss,
         takeProfit,
         "RSI-DUAL Sell"
      );


   if(placed)
     {
      tradesToday++;

      StoreNewTradeInformation();

      Print(
         "RSI-DUAL SELL",
         " | Lots = ",
         lots,
         " | SL = ",
         stopLoss,
         " | TP = ",
         takeProfit
      );
     }
   else
     {
      Print(
         "SELL Failed: ",
         trade.ResultRetcodeDescription()
      );
     }


   shortSetupActive = false;
  }


//+------------------------------------------------------------------+
//| Helper: Check Exits                                              |
//+------------------------------------------------------------------+
void CheckExits()
  {
   ulong ticket =
      GetMyPositionTicket();


   if(ticket == 0)
      return;


   if(!PositionSelectByTicket(ticket))
      return;


   long type =
      PositionGetInteger(
         POSITION_TYPE
      );


   // ==============================================================
   // EXIT 1:
   // VWAP Regime Kill
   // ==============================================================

   if(Use_VWAP_Exit)
     {
      double vwap =
         CalculateSessionVWAP(1);


      double prevClose =
         iClose(
            _Symbol,
            Entry_Timeframe,
            1
         );


      if(vwap > 0.0)
        {
         // LONG:
         // M5 closes below VWAP
         if(type == POSITION_TYPE_BUY &&
            prevClose < vwap)
           {
            Print(
               "Close BUY: M5 Closed Below VWAP"
            );

            trade.PositionClose(ticket);

            return;
           }


         // SHORT:
         // M5 closes above VWAP
         if(type == POSITION_TYPE_SELL &&
            prevClose > vwap)
           {
            Print(
               "Close SELL: M5 Closed Above VWAP"
            );

            trade.PositionClose(ticket);

            return;
           }
        }
     }


   // ==============================================================
   // EXIT 2:
   // TIME STOP
   //
   // If +1R was not reached within 8 M5 candles -> Exit
   // ==============================================================

   if(Use_Time_Stop &&
      !reachedRequiredR)
     {
      int barsOpen =
         iBarShift(
            _Symbol,
            Entry_Timeframe,
            currentTradeOpenTime,
            false
         );


      if(barsOpen >= Max_Candles)
        {
         Print(
            "Close Position: Time Stop"
         );

         trade.PositionClose(ticket);

         return;
        }
     }
  }


//+------------------------------------------------------------------+
//| Helper: Track +Required R Intrabar                               |
//+------------------------------------------------------------------+
void TrackTradeProgress()
  {
   ulong ticket =
      GetMyPositionTicket();


   if(ticket == 0)
      return;


   if(!PositionSelectByTicket(ticket))
      return;


   if(reachedRequiredR)
      return;


   if(currentInitialRisk <= 0.0)
      return;


   long type =
      PositionGetInteger(
         POSITION_TYPE
      );


   double price = 0.0;


   if(type == POSITION_TYPE_BUY)
     {
      price =
         SymbolInfoDouble(
            _Symbol,
            SYMBOL_BID
         );


      double favorableMove =
         price -
         currentEntryPrice;


      if(favorableMove >=
         Required_R *
         currentInitialRisk)
        {
         reachedRequiredR = true;
        }
     }


   if(type == POSITION_TYPE_SELL)
     {
      price =
         SymbolInfoDouble(
            _Symbol,
            SYMBOL_ASK
         );


      double favorableMove =
         currentEntryPrice -
         price;


      if(favorableMove >=
         Required_R *
         currentInitialRisk)
        {
         reachedRequiredR = true;
        }
     }
  }


//+------------------------------------------------------------------+
//| Helper: Store New Trade Information                              |
//+------------------------------------------------------------------+
void StoreNewTradeInformation()
  {
   ulong ticket =
      GetMyPositionTicket();


   if(ticket == 0)
      return;


   if(!PositionSelectByTicket(ticket))
      return;


   currentEntryPrice =
      PositionGetDouble(
         POSITION_PRICE_OPEN
      );


   double stopLoss =
      PositionGetDouble(
         POSITION_SL
      );


   currentInitialRisk =
      MathAbs(
         currentEntryPrice -
         stopLoss
      );


   currentTradeOpenTime =
      (datetime)PositionGetInteger(
         POSITION_TIME
      );


   reachedRequiredR = false;
  }


//+------------------------------------------------------------------+
//| Helper: Check Long Regime                                        |
//+------------------------------------------------------------------+
bool IsLongRegimeValid()
  {
   if(longRegimeKilled)
      return false;


   // --- M15 RSI > 50 ---

   double regimeRSI =
      GetIndicatorValue(
         h_RegimeRSI,
         1
      );


   if(regimeRSI <= Long_Regime_Level)
      return false;


   // --- Signal Candle Price > VWAP ---

   double signalClose =
      iClose(
         _Symbol,
         Entry_Timeframe,
         1
      );


   double vwap =
      CalculateSessionVWAP(1);


   if(vwap <= 0.0)
      return false;


   if(signalClose <= vwap)
      return false;


   // --- Afternoon must retain Morning Long Regime ---

   if(IsAfternoonSession() &&
      longRegimeBrokenToday)
      return false;


   return true;
  }


//+------------------------------------------------------------------+
//| Helper: Check Short Regime                                       |
//+------------------------------------------------------------------+
bool IsShortRegimeValid()
  {
   if(shortRegimeKilled)
      return false;


   // --- M15 RSI < 50 ---

   double regimeRSI =
      GetIndicatorValue(
         h_RegimeRSI,
         1
      );


   if(regimeRSI >= Short_Regime_Level)
      return false;


   // --- Signal Candle Price < VWAP ---

   double signalClose =
      iClose(
         _Symbol,
         Entry_Timeframe,
         1
      );


   double vwap =
      CalculateSessionVWAP(1);


   if(vwap <= 0.0)
      return false;


   if(signalClose >= vwap)
      return false;


   // --- Afternoon must retain Morning Short Regime ---

   if(IsAfternoonSession() &&
      shortRegimeBrokenToday)
      return false;


   return true;
  }


//+------------------------------------------------------------------+
//| Helper: Update M15 Regime State                                  |
//+------------------------------------------------------------------+
void UpdateRegimeState()
  {
   double rsi =
      GetIndicatorValue(
         h_RegimeRSI,
         1
      );


   if(rsi < 0.0)
      return;


   // ==============================================================
   // LONG REGIME KILL
   //
   // First M15 RSI close < 40 kills current Long Regime.
   //
   // Short regime is allowed to begin again from scratch.
   // ==============================================================

   if(rsi < Long_Regime_Kill)
     {
      longRegimeKilled = true;

      longRegimeBrokenToday = true;

      longSetupActive = false;


      // Opposite Regime can now rebuild from scratch
      shortRegimeKilled = false;
     }


   // ==============================================================
   // SHORT REGIME KILL
   //
   // First M15 RSI close > 60 kills current Short Regime.
   //
   // Long regime is allowed to begin again from scratch.
   // ==============================================================

   if(rsi > Short_Regime_Kill)
     {
      shortRegimeKilled = true;

      shortRegimeBrokenToday = true;

      shortSetupActive = false;


      // Opposite Regime can rebuild from scratch
      longRegimeKilled = false;
     }
  }


//+------------------------------------------------------------------+
//| Helper: Calculate Session VWAP                                   |
//+------------------------------------------------------------------+
double CalculateSessionVWAP(int signalShift)
  {
   // ==============================================================
   // VWAP Start = 09:30 New York
   // ==============================================================

   datetime vwapStart =
      GetServerTimeForNYToday(
         VWAP_Start_Hour,
         VWAP_Start_Minute
      );


   int startShift =
      iBarShift(
         _Symbol,
         Entry_Timeframe,
         vwapStart,
         false
      );


   if(startShift < 0)
      return 0.0;


   if(startShift < signalShift)
      return 0.0;


   double priceVolumeSum = 0.0;

   double volumeSum = 0.0;


   // ==============================================================
   // Calculate Typical Price * Tick Volume
   // ==============================================================

   for(int i = startShift;
       i >= signalShift;
       i--)
     {
      double high =
         iHigh(
            _Symbol,
            Entry_Timeframe,
            i
         );


      double low =
         iLow(
            _Symbol,
            Entry_Timeframe,
            i
         );


      double close =
         iClose(
            _Symbol,
            Entry_Timeframe,
            i
         );


      long volume =
         iVolume(
            _Symbol,
            Entry_Timeframe,
            i
         );


      if(volume <= 0)
         continue;


      double typicalPrice =
         (
            high +
            low +
            close
         )
         /
         3.0;


      priceVolumeSum +=
         typicalPrice *
         (double)volume;


      volumeSum +=
         (double)volume;
     }


   if(volumeSum <= 0.0)
      return 0.0;


   return
      priceVolumeSum /
      volumeSum;
  }


//+------------------------------------------------------------------+
//| Helper: Find Last Major Higher Low                               |
//+------------------------------------------------------------------+
double FindLastHigherLow()
  {
   double recentSwingLow = 0.0;

   double previousSwingLow = 0.0;

   int swingsFound = 0;


   int startShift =
      Swing_Right_Bars + 1;


   for(int shift = startShift;
       shift <
       startShift +
       Swing_Search_Bars;
       shift++)
     {
      if(IsSwingLow(shift))
        {
         double swingLow =
            iLow(
               _Symbol,
               Entry_Timeframe,
               shift
            );


         if(swingsFound == 0)
           {
            recentSwingLow =
               swingLow;

            swingsFound++;
           }
         else
           {
            previousSwingLow =
               swingLow;

            swingsFound++;

            break;
           }
        }
     }


   if(swingsFound < 2)
      return 0.0;


   // Latest Swing Low must be HIGHER
   // than previous Swing Low

   if(recentSwingLow >
      previousSwingLow)
     {
      return recentSwingLow;
     }


   return 0.0;
  }


//+------------------------------------------------------------------+
//| Helper: Find Last Major Lower High                               |
//+------------------------------------------------------------------+
double FindLastLowerHigh()
  {
   double recentSwingHigh = 0.0;

   double previousSwingHigh = 0.0;

   int swingsFound = 0;


   int startShift =
      Swing_Right_Bars + 1;


   for(int shift = startShift;
       shift <
       startShift +
       Swing_Search_Bars;
       shift++)
     {
      if(IsSwingHigh(shift))
        {
         double swingHigh =
            iHigh(
               _Symbol,
               Entry_Timeframe,
               shift
            );


         if(swingsFound == 0)
           {
            recentSwingHigh =
               swingHigh;

            swingsFound++;
           }
         else
           {
            previousSwingHigh =
               swingHigh;

            swingsFound++;

            break;
           }
        }
     }


   if(swingsFound < 2)
      return 0.0;


   // Latest Swing High must be LOWER
   // than previous Swing High

   if(recentSwingHigh <
      previousSwingHigh)
     {
      return recentSwingHigh;
     }


   return 0.0;
  }


//+------------------------------------------------------------------+
//| Helper: Is Swing Low                                             |
//+------------------------------------------------------------------+
bool IsSwingLow(int shift)
  {
   double candidate =
      iLow(
         _Symbol,
         Entry_Timeframe,
         shift
      );


   if(candidate <= 0.0)
      return false;


   // Older candles
   for(int i = 1;
       i <= Swing_Left_Bars;
       i++)
     {
      double otherLow =
         iLow(
            _Symbol,
            Entry_Timeframe,
            shift + i
         );


      if(otherLow <= candidate)
         return false;
     }


   // Newer CLOSED candles
   for(int i = 1;
       i <= Swing_Right_Bars;
       i++)
     {
      if(shift - i < 1)
         return false;


      double otherLow =
         iLow(
            _Symbol,
            Entry_Timeframe,
            shift - i
         );


      if(otherLow <= candidate)
         return false;
     }


   return true;
  }


//+------------------------------------------------------------------+
//| Helper: Is Swing High                                            |
//+------------------------------------------------------------------+
bool IsSwingHigh(int shift)
  {
   double candidate =
      iHigh(
         _Symbol,
         Entry_Timeframe,
         shift
      );


   if(candidate <= 0.0)
      return false;


   // Older candles
   for(int i = 1;
       i <= Swing_Left_Bars;
       i++)
     {
      double otherHigh =
         iHigh(
            _Symbol,
            Entry_Timeframe,
            shift + i
         );


      if(otherHigh >= candidate)
         return false;
     }


   // Newer CLOSED candles
   for(int i = 1;
       i <= Swing_Right_Bars;
       i++)
     {
      if(shift - i < 1)
         return false;


      double otherHigh =
         iHigh(
            _Symbol,
            Entry_Timeframe,
            shift - i
         );


      if(otherHigh >= candidate)
         return false;
     }


   return true;
  }


//+------------------------------------------------------------------+
//| Helper: Highest High                                             |
//+------------------------------------------------------------------+
double GetHighestHigh(int bars, int startShift)
  {
   double highest =
      -DBL_MAX;


   for(int i = startShift;
       i <
       startShift + bars;
       i++)
     {
      double high =
         iHigh(
            _Symbol,
            Entry_Timeframe,
            i
         );


      if(high > highest)
         highest = high;
     }


   return highest;
  }


//+------------------------------------------------------------------+
//| Helper: Lowest Low                                               |
//+------------------------------------------------------------------+
double GetLowestLow(int bars, int startShift)
  {
   double lowest =
      DBL_MAX;


   for(int i = startShift;
       i <
       startShift + bars;
       i++)
     {
      double low =
         iLow(
            _Symbol,
            Entry_Timeframe,
            i
         );


      if(low < lowest)
         lowest = low;
     }


   return lowest;
  }


//+------------------------------------------------------------------+
//| Helper: Get Indicator Value                                      |
//+------------------------------------------------------------------+
double GetIndicatorValue(int handle, int shift)
  {
   double value[1];


   if(CopyBuffer(
         handle,
         0,
         shift,
         1,
         value
      ) != 1)
     {
      return -1.0;
     }


   return value[0];
  }


//+------------------------------------------------------------------+
//| Helper: Calculate Lot Size                                       |
//+------------------------------------------------------------------+
double CalculateLotSize(
   double entryPrice,
   double stopPrice
)
  {
   // ==============================================================
   // Fixed Lot Mode
   // ==============================================================

   if(!Use_Risk_Percent)
     {
      return
         NormalizeVolume(
            LotSize
         );
     }


   // ==============================================================
   // Risk Based Position Size
   // ==============================================================

   double stopDistance =
      MathAbs(
         entryPrice -
         stopPrice
      );


   if(stopDistance <= 0.0)
      return 0.0;


   double riskMoney =
      AccountInfoDouble(
         ACCOUNT_EQUITY
      )
      *
      Risk_Percent /
      100.0;


   double tickSize =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_TRADE_TICK_SIZE
      );


   double tickValue =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_TRADE_TICK_VALUE_LOSS
      );


   if(tickValue <= 0.0)
     {
      tickValue =
         SymbolInfoDouble(
            _Symbol,
            SYMBOL_TRADE_TICK_VALUE
         );
     }


   if(tickSize <= 0.0 ||
      tickValue <= 0.0)
     {
      return 0.0;
     }


   double moneyLossPerLot =
      (
         stopDistance /
         tickSize
      )
      *
      tickValue;


   if(moneyLossPerLot <= 0.0)
      return 0.0;


   double lots =
      riskMoney /
      moneyLossPerLot;


   return
      NormalizeVolume(
         lots
      );
  }


//+------------------------------------------------------------------+
//| Helper: Normalize Volume                                         |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
  {
   double minLot =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MIN
      );


   double maxLot =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MAX
      );


   double lotStep =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_STEP
      );


   if(lotStep <= 0.0)
      return 0.0;


   // Do not exceed requested risk just because
   // broker minimum volume is larger.
   if(Use_Risk_Percent &&
      volume < minLot)
     {
      return 0.0;
     }


   volume =
      MathMax(
         minLot,
         MathMin(
            maxLot,
            volume
         )
      );


   volume =
      MathFloor(
         volume /
         lotStep
      )
      *
      lotStep;


   return
      NormalizeDouble(
         volume,
         8
      );
  }


//+------------------------------------------------------------------+
//| Helper: Normalize Price                                          |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
  {
   double tickSize =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_TRADE_TICK_SIZE
      );


   if(tickSize <= 0.0)
     {
      return
         NormalizeDouble(
            price,
            _Digits
         );
     }


   price =
      MathRound(
         price /
         tickSize
      )
      *
      tickSize;


   return
      NormalizeDouble(
         price,
         _Digits
      );
  }


//+------------------------------------------------------------------+
//| Helper: Trading Allowed                                          |
//+------------------------------------------------------------------+
bool TradingAllowed()
  {
   // --- Max Trades ---

   if(tradesToday >=
      Max_Trades_Per_Day)
     {
      return false;
     }


   // --- Max Daily Losing Trades ---

   if(lossesToday >=
      Max_Losses_Per_Day)
     {
      return false;
     }


   // --- Daily Equity Stop ---

   if(Use_Daily_Loss_Limit &&
      dayStartEquity > 0.0)
     {
      double currentEquity =
         AccountInfoDouble(
            ACCOUNT_EQUITY
         );


      double lossPercent =
         (
            dayStartEquity -
            currentEquity
         )
         /
         dayStartEquity
         *
         100.0;


      if(lossPercent >=
         Daily_Loss_Percent)
        {
         return false;
        }
     }


   // --- Weekly Equity Stop ---

   if(Use_Weekly_Loss_Limit &&
      weekStartEquity > 0.0)
     {
      double currentEquity =
         AccountInfoDouble(
            ACCOUNT_EQUITY
         );


      double lossPercent =
         (
            weekStartEquity -
            currentEquity
         )
         /
         weekStartEquity
         *
         100.0;


      if(lossPercent >=
         Weekly_Loss_Percent)
        {
         return false;
        }
     }


   return true;
  }


//+------------------------------------------------------------------+
//| Helper: Check Entry Session                                      |
//+------------------------------------------------------------------+
bool IsEntrySession()
  {
   // Use the CLOSE TIME of the latest completed M5 candle.

   datetime signalCloseTime =
      iTime(
         _Symbol,
         Entry_Timeframe,
         1
      )
      +
      PeriodSeconds(
         Entry_Timeframe
      );


   datetime nyTime =
      signalCloseTime +
      (
         NY_Offset_From_Server *
         3600
      );


   MqlDateTime dt;

   TimeToStruct(
      nyTime,
      dt
   );


   int currentMinutes =
      dt.hour * 60 +
      dt.min;


   int morningStart =
      Morning_Start_Hour * 60 +
      Morning_Start_Minute;


   int morningEnd =
      Morning_End_Hour * 60 +
      Morning_End_Minute;


   bool morning =
      (
         currentMinutes >= morningStart
         &&
         currentMinutes <= morningEnd
      );


   bool afternoon = false;


   if(Use_Afternoon_Session)
     {
      int afternoonStart =
         Afternoon_Start_Hour * 60 +
         Afternoon_Start_Minute;


      int afternoonEnd =
         Afternoon_End_Hour * 60 +
         Afternoon_End_Minute;


      afternoon =
         (
            currentMinutes >= afternoonStart
            &&
            currentMinutes <= afternoonEnd
         );
     }


   return
      morning ||
      afternoon;
  }


//+------------------------------------------------------------------+
//| Helper: Is Afternoon Session                                     |
//+------------------------------------------------------------------+
bool IsAfternoonSession()
  {
   datetime signalCloseTime =
      iTime(
         _Symbol,
         Entry_Timeframe,
         1
      )
      +
      PeriodSeconds(
         Entry_Timeframe
      );


   datetime nyTime =
      signalCloseTime +
      (
         NY_Offset_From_Server *
         3600
      );


   MqlDateTime dt;

   TimeToStruct(
      nyTime,
      dt
   );


   int currentMinutes =
      dt.hour * 60 +
      dt.min;


   int startMinutes =
      Afternoon_Start_Hour * 60 +
      Afternoon_Start_Minute;


   int endMinutes =
      Afternoon_End_Hour * 60 +
      Afternoon_End_Minute;


   return
      (
         currentMinutes >= startMinutes
         &&
         currentMinutes <= endMinutes
      );
  }


//+------------------------------------------------------------------+
//| Helper: Check Time                                               |
//+------------------------------------------------------------------+
bool IsTimeReached(int hour, int minute)
  {
   datetime currentNY =
      TimeCurrent() +
      (
         NY_Offset_From_Server *
         3600
      );


   MqlDateTime dt;

   TimeToStruct(
      currentNY,
      dt
   );


   int currentMinutes =
      dt.hour * 60 +
      dt.min;


   int requestedMinutes =
      hour * 60 +
      minute;


   return
      currentMinutes >=
      requestedMinutes;
  }


//+------------------------------------------------------------------+
//| Helper: Server Time for Today's NY Time                          |
//+------------------------------------------------------------------+
datetime GetServerTimeForNYToday(
   int hour,
   int minute
)
  {
   datetime currentNY =
      TimeCurrent() +
      (
         NY_Offset_From_Server *
         3600
      );


   MqlDateTime dt;

   TimeToStruct(
      currentNY,
      dt
   );


   dt.hour = hour;
   dt.min  = minute;
   dt.sec  = 0;


   datetime requestedNY =
      StructToTime(dt);


   return
      requestedNY -
      (
         NY_Offset_From_Server *
         3600
      );
  }


//+------------------------------------------------------------------+
//| Helper: New M5 Bar                                               |
//+------------------------------------------------------------------+
bool isNewBar()
  {
   datetime current =
      iTime(
         _Symbol,
         Entry_Timeframe,
         0
      );


   if(lastEntryBarTime != current)
     {
      lastEntryBarTime =
         current;

      return true;
     }


   return false;
  }


//+------------------------------------------------------------------+
//| Helper: New M15 Regime Bar                                       |
//+------------------------------------------------------------------+
bool isNewRegimeBar()
  {
   datetime current =
      iTime(
         _Symbol,
         Regime_Timeframe,
         0
      );


   if(lastRegimeBarTime != current)
     {
      lastRegimeBarTime =
         current;

      return true;
     }


   return false;
  }


//+------------------------------------------------------------------+
//| Helper: Check Open Position                                      |
//+------------------------------------------------------------------+
bool DoesMyPositionExist()
  {
   for(int i = PositionsTotal() - 1;
       i >= 0;
       i--)
     {
      ulong ticket =
         PositionGetTicket(i);


      if(ticket == 0)
         continue;


      if(PositionGetString(
            POSITION_SYMBOL
         ) != _Symbol)
         continue;


      if(PositionGetInteger(
            POSITION_MAGIC
         ) != MagicNumber)
         continue;


      return true;
     }


   return false;
  }


//+------------------------------------------------------------------+
//| Helper: Get Position Ticket                                      |
//+------------------------------------------------------------------+
ulong GetMyPositionTicket()
  {
   for(int i = PositionsTotal() - 1;
       i >= 0;
       i--)
     {
      ulong ticket =
         PositionGetTicket(i);


      if(ticket == 0)
         continue;


      if(PositionGetString(
            POSITION_SYMBOL
         ) != _Symbol)
         continue;


      if(PositionGetInteger(
            POSITION_MAGIC
         ) != MagicNumber)
         continue;


      return ticket;
     }


   return 0;
  }


//+------------------------------------------------------------------+
//| Helper: Close My Position                                        |
//+------------------------------------------------------------------+
void CloseMyPosition()
  {
   ulong ticket =
      GetMyPositionTicket();


   if(ticket > 0)
     {
      trade.PositionClose(
         ticket
      );
     }
  }


//+------------------------------------------------------------------+
//| Helper: Check New NY Day / Week                                  |
//+------------------------------------------------------------------+
void CheckNewDay()
  {
   datetime currentNY =
      TimeCurrent() +
      (
         NY_Offset_From_Server *
         3600
      );


   MqlDateTime dt;

   TimeToStruct(
      currentNY,
      dt
   );


   // ==============================================================
   // DAILY RESET
   // ==============================================================

   int dayKey =
      dt.year * 1000 +
      dt.day_of_year;


   if(dayKey != currentDay)
     {
      currentDay =
         dayKey;


      tradesToday = 0;
      lossesToday = 0;


      consecutiveLongLosses  = 0;
      consecutiveShortLosses = 0;


      longSetupActive  = false;
      shortSetupActive = false;


      longRegimeKilled  = false;
      shortRegimeKilled = false;


      longRegimeBrokenToday  = false;
      shortRegimeBrokenToday = false;


      dayStartEquity =
         AccountInfoDouble(
            ACCOUNT_EQUITY
         );
     }


   // ==============================================================
   // WEEKLY RESET
   // ==============================================================

   MqlDateTime midnightStruct =
      dt;


   midnightStruct.hour = 0;
   midnightStruct.min  = 0;
   midnightStruct.sec  = 0;


   datetime todayMidnight =
      StructToTime(
         midnightStruct
      );


   // MQL5:
   // Sunday = 0
   // Monday = 1
   //
   // Convert to number of days since Monday.

   int daysSinceMonday =
      (
         dt.day_of_week +
         6
      )
      %
      7;


   datetime monday =
      todayMidnight -
      (
         daysSinceMonday *
         86400
      );


   if(monday != currentWeek)
     {
      currentWeek =
         monday;


      weekStartEquity =
         AccountInfoDouble(
            ACCOUNT_EQUITY
         );
     }
  }


//+------------------------------------------------------------------+
//| Trade Transaction                                                |
//| Track losing BUY / SELL trades                                   |
//+------------------------------------------------------------------+
void OnTradeTransaction(
   const MqlTradeTransaction &trans,
   const MqlTradeRequest &request,
   const MqlTradeResult &result
)
  {
   if(trans.type !=
      TRADE_TRANSACTION_DEAL_ADD)
     {
      return;
     }


   if(trans.deal == 0)
      return;


   if(!HistoryDealSelect(
         trans.deal
      ))
     {
      return;
     }


   // --- Only this EA ---

   long magic =
      HistoryDealGetInteger(
         trans.deal,
         DEAL_MAGIC
      );


   if(magic != MagicNumber)
      return;


   // --- Only Closing Deals ---

   long entryType =
      HistoryDealGetInteger(
         trans.deal,
         DEAL_ENTRY
      );


   if(entryType != DEAL_ENTRY_OUT &&
      entryType != DEAL_ENTRY_OUT_BY)
     {
      return;
     }


   // ==============================================================
   // Calculate Net Result
   // ==============================================================

   double profit =
      HistoryDealGetDouble(
         trans.deal,
         DEAL_PROFIT
      );


   double commission =
      HistoryDealGetDouble(
         trans.deal,
         DEAL_COMMISSION
      );


   double swap =
      HistoryDealGetDouble(
         trans.deal,
         DEAL_SWAP
      );


   double netResult =
      profit +
      commission +
      swap;


   // Closing Deal Type:
   //
   // SELL close = Original position was BUY
   // BUY close  = Original position was SELL

   long dealType =
      HistoryDealGetInteger(
         trans.deal,
         DEAL_TYPE
      );


   // ==============================================================
   // ORIGINAL TRADE WAS LONG
   // ==============================================================

   if(dealType == DEAL_TYPE_SELL)
     {
      if(netResult < 0.0)
        {
         lossesToday++;

         consecutiveLongLosses++;
        }
      else
        {
         consecutiveLongLosses = 0;
        }
     }


   // ==============================================================
   // ORIGINAL TRADE WAS SHORT
   // ==============================================================

   if(dealType == DEAL_TYPE_BUY)
     {
      if(netResult < 0.0)
        {
         lossesToday++;

         consecutiveShortLosses++;
        }
      else
        {
         consecutiveShortLosses = 0;
        }
     }


   // ==============================================================
   // Reset Current Trade Tracking
   // ==============================================================

   currentEntryPrice = 0.0;

   currentInitialRisk = 0.0;

   currentTradeOpenTime = 0;

   reachedRequiredR = false;
  }