#property copyright "Copyright 2026, Built for User"
#property link      "https://www.mql5.com"
#property version   "4.00"

#include <Trade/Trade.mqh>

// ==================================================================
// EA INPUTS
// ==================================================================

input ENUM_TIMEFRAMES Timeframe          = PERIOD_M5;


// ==================================================================
// OPENING RANGE SETTINGS
// ==================================================================

input int             Range_Start_Hour   = 9;
input int             Range_Start_Minute = 30;

input int             Range_End_Hour     = 10;
input int             Range_End_Minute   = 0;


// ==================================================================
// ENTRY SETTINGS
// ==================================================================

// false = only first breakout direction is traded
// true  = opposite breakout can also be traded once
input bool            Allow_Both_Sides   = false;


// ==================================================================
// ATR BUFFER SETTINGS
// ==================================================================

input int             ATR_Period         = 14;

// Example:
// ATR = 20
// Multiplier = 0.10
// Buffer = 2 points
input double          ATR_Buffer_Mult    = 0.10;


// ==================================================================
// LOT SIZE / RISK SETTINGS
// ==================================================================

// true  = Always use Fixed_Lot_Size
// false = Calculate lot size from Risk_Percent
input bool            Use_Fixed_Lot      = true;

input double          Fixed_Lot_Size     = 0.10;

input double          Risk_Percent       = 2.0;


// ==================================================================
// END OF DAY EXIT
// ==================================================================

input int             EOD_Hour           = 15;
input int             EOD_Minute         = 55;


// ==================================================================
// VISUAL SETTINGS
// ==================================================================

input bool            Draw_Range         = true;

input color           Range_High_Color   = clrLimeGreen;
input color           Range_Low_Color    = clrTomato;

input color           Range_Fill_Color   = clrGoldenrod;
input int             Range_Fill_Alpha   = 35;

input int             Range_Line_Width   = 1;


// ==================================================================
// LOGGER SETTINGS
// ==================================================================

input bool            Enable_Logs        = true;
input bool            Log_Every_Tick     = false;
input bool            Log_Range          = true;
input bool            Log_Entry          = true;
input bool            Log_Risk           = true;
input bool            Log_Trade          = true;


// ==================================================================
// TRADE SETTINGS
// ==================================================================

input int             MagicNumber        = 35791;
input int             SlippagePoints     = 20;


// ==================================================================
// GLOBAL VARIABLES
// ==================================================================

CTrade trade;

int h_ATR;


// --- Opening Range ---

double rangeHigh = 0.0;
double rangeLow  = 0.0;


// --- Breakout Levels ---

double buyEntryPrice  = 0.0;
double sellEntryPrice = 0.0;

double atrBuffer = 0.0;


// --- Daily State ---

bool rangeReady       = false;
bool entryLevelsReady = false;

bool firstTradeOpened  = false;
bool secondTradeOpened = false;

bool dailyTradingEnded = false;


//  1 = BUY
// -1 = SELL
//  0 = NONE

int firstDirection = 0;


// Used for more reliable breakout detection
double previousAsk = 0.0;
double previousBid = 0.0;


// Day tracking
int currentDay  = -1;
int currentYear = -1;


// ==================================================================
// DRAWING OBJECTS
// ==================================================================

string rangeRectangleName;
string rangeHighLineName;
string rangeLowLineName;

string buyLevelLineName;
string sellLevelLineName;


//+------------------------------------------------------------------+
//| Expert Initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   // ===============================================================
   // 1. ATR HANDLE
   // ===============================================================

   h_ATR =
      iATR(
         _Symbol,
         Timeframe,
         ATR_Period
      );


   if(h_ATR == INVALID_HANDLE)
     {
      Print("[ORB][INIT] ERROR creating ATR handle.");

      return(INIT_FAILED);
     }


   // ===============================================================
   // 2. TRADE SETTINGS
   // ===============================================================

   trade.SetExpertMagicNumber(
      MagicNumber
   );


   trade.SetDeviationInPoints(
      SlippagePoints
   );


   trade.SetAsyncMode(
      false
   );


   trade.SetTypeFillingBySymbol(
      _Symbol
   );


   // ===============================================================
   // 3. CURRENT DAY
   // ===============================================================

   MqlDateTime dt;

   TimeToStruct(
      TimeCurrent(),
      dt
   );


   currentDay  = dt.day_of_year;
   currentYear = dt.year;


   // ===============================================================
   // 4. OBJECT NAMES
   // ===============================================================

   SetObjectNames();


   // ===============================================================
   // 5. INITIAL PRICE
   // ===============================================================

   MqlTick tick;

   if(SymbolInfoTick(
         _Symbol,
         tick
      ))
     {
      previousAsk = tick.ask;
      previousBid = tick.bid;
     }


   // ===============================================================
   // 6. LOGGER
   // ===============================================================

   Log(
      "INIT",
      "EA INITIALIZED"
      " | Symbol=" + _Symbol +
      " | Timeframe=" + EnumToString(Timeframe) +
      " | Range=" +
      TimeText(
         Range_Start_Hour,
         Range_Start_Minute
      ) +
      " -> " +
      TimeText(
         Range_End_Hour,
         Range_End_Minute
      ) +
      " | FixedLotMode=" +
      BoolText(Use_Fixed_Lot) +
      " | FixedLot=" +
      DoubleToString(Fixed_Lot_Size, 2) +
      " | Risk%=" +
      DoubleToString(Risk_Percent, 2) +
      " | BothSides=" +
      BoolText(Allow_Both_Sides)
   );


   return(INIT_SUCCEEDED);
  }


//+------------------------------------------------------------------+
//| Expert Deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(
      h_ATR
   );


   Log(
      "DEINIT",
      "EA removed | Reason=" +
      IntegerToString(reason)
   );
  }


//+------------------------------------------------------------------+
//| Expert Tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
  {
   // ===============================================================
   // 1. CHECK NEW DAY
   // ===============================================================

   CheckNewDay();


   // ===============================================================
   // 2. GET CURRENT TICK
   // ===============================================================

   MqlTick tick;


   if(!SymbolInfoTick(
         _Symbol,
         tick
      ))
     {
      Log(
         "ERROR",
         "SymbolInfoTick failed."
      );

      return;
     }


   // ===============================================================
   // 3. OPTIONAL TICK LOGGER
   // ===============================================================

   if(Log_Every_Tick)
     {
      Log(
         "TICK",
         "Bid=" +
         DoubleToString(tick.bid, _Digits) +
         " | Ask=" +
         DoubleToString(tick.ask, _Digits) +
         " | PrevBid=" +
         DoubleToString(previousBid, _Digits) +
         " | PrevAsk=" +
         DoubleToString(previousAsk, _Digits) +
         " | RangeReady=" +
         BoolText(rangeReady) +
         " | LevelsReady=" +
         BoolText(entryLevelsReady) +
         " | FirstTrade=" +
         BoolText(firstTradeOpened) +
         " | SecondTrade=" +
         BoolText(secondTradeOpened)
      );
     }


   // ===============================================================
   // 4. END OF DAY
   // ===============================================================

   if(IsEOD())
     {
      if(!dailyTradingEnded)
        {
         Log(
            "EOD",
            "EOD reached. Closing all positions."
         );


         CloseAllPositions();


         dailyTradingEnded = true;


         Log(
            "EOD",
            "EOD cleanup complete."
         );
        }


      previousAsk = tick.ask;
      previousBid = tick.bid;


      return;
     }


   // ===============================================================
   // 5. BUILD / FINALIZE OPENING RANGE
   // ===============================================================

   UpdateOpeningRange();


   if(!rangeReady)
     {
      previousAsk = tick.ask;
      previousBid = tick.bid;

      return;
     }


   // ===============================================================
   // 6. CALCULATE BREAKOUT LEVELS
   // ===============================================================

   if(!entryLevelsReady)
     {
      CalculateBreakoutLevels();


      if(!entryLevelsReady)
        {
         previousAsk = tick.ask;
         previousBid = tick.bid;

         return;
        }
     }


   // ===============================================================
   // 7. CHECK BREAKOUT ON EVERY TICK
   //
   // ONLY MARKET ORDERS ARE USED.
   //
   // NO BUY STOP.
   // NO SELL STOP.
   // NO PENDING ORDERS.
   // ===============================================================

   CheckBreakout(
      tick
   );


   // ===============================================================
   // 8. SAVE CURRENT PRICES
   // ===============================================================

   previousAsk = tick.ask;
   previousBid = tick.bid;
  }


//+------------------------------------------------------------------+
//| Helper: Build Opening Range                                      |
//+------------------------------------------------------------------+
void UpdateOpeningRange()
  {
   datetime now =
      TimeCurrent();


   datetime rangeStart =
      GetTodayTime(
         Range_Start_Hour,
         Range_Start_Minute
      );


   datetime rangeEnd =
      GetTodayTime(
         Range_End_Hour,
         Range_End_Minute
      );


   // ===============================================================
   // RANGE HAS NOT STARTED
   // ===============================================================

   if(now < rangeStart)
      return;


   // ===============================================================
   // RANGE IS CURRENTLY FORMING
   // ===============================================================

   if(now >= rangeStart &&
      now < rangeEnd)
     {
      if(!CalculateRangeFromHistory(
            rangeStart,
            now
         ))
        {
         if(Log_Range)
           {
            Log(
               "RANGE",
               "Unable to calculate forming range."
            );
           }


         return;
        }


      // ------------------------------------------------------------
      // Include current live market price
      // ------------------------------------------------------------

      MqlTick tick;


      if(SymbolInfoTick(
            _Symbol,
            tick
         ))
        {
         if(tick.ask > rangeHigh)
            rangeHigh = tick.ask;


         if(tick.bid < rangeLow)
            rangeLow = tick.bid;
        }


      // ------------------------------------------------------------
      // Draw live rectangle
      // ------------------------------------------------------------

      if(Draw_Range)
        {
         DrawOpeningRange(
            rangeStart,
            now
         );
        }


      return;
     }


   // ===============================================================
   // FINALIZE RANGE
   // ===============================================================

   if(now >= rangeEnd &&
      !rangeReady)
     {
      Log(
         "RANGE",
         "Range period finished. Finalizing opening range."
      );


      // ------------------------------------------------------------
      // rangeEnd - 1 second prevents inclusion of the candle
      // beginning exactly at Range_End.
      // ------------------------------------------------------------

      if(!CalculateRangeFromHistory(
            rangeStart,
            rangeEnd - 1
         ))
        {
         Log(
            "RANGE",
            "FINAL RANGE CALCULATION FAILED."
         );


         return;
        }


      if(rangeHigh <= rangeLow)
        {
         Log(
            "RANGE",
            "INVALID RANGE | High=" +
            DoubleToString(rangeHigh, _Digits) +
            " | Low=" +
            DoubleToString(rangeLow, _Digits)
         );


         return;
        }


      rangeReady =
         true;


      if(Draw_Range)
        {
         DrawOpeningRange(
            rangeStart,
            rangeEnd
         );
        }


      Log(
         "RANGE",
         "FINAL RANGE READY"
         " | High=" +
         DoubleToString(rangeHigh, _Digits) +
         " | Low=" +
         DoubleToString(rangeLow, _Digits) +
         " | RangeSize=" +
         DoubleToString(
            rangeHigh - rangeLow,
            _Digits
         )
      );
     }
  }


//+------------------------------------------------------------------+
//| Helper: Calculate Range From Historical Data                     |
//+------------------------------------------------------------------+
bool CalculateRangeFromHistory(
   datetime startTime,
   datetime endTime
)
  {
   MqlRates rates[];


   ResetLastError();


   int copied =
      CopyRates(
         _Symbol,
         Timeframe,
         startTime,
         endTime,
         rates
      );


   if(copied <= 0)
     {
      Log(
         "RANGE_ERROR",
         "CopyRates failed"
         " | Start=" +
         TimeToString(
            startTime,
            TIME_DATE | TIME_MINUTES
         ) +
         " | End=" +
         TimeToString(
            endTime,
            TIME_DATE | TIME_MINUTES
         ) +
         " | Copied=" +
         IntegerToString(copied) +
         " | Error=" +
         IntegerToString(
            GetLastError()
         )
      );


      return false;
     }


   rangeHigh =
      rates[0].high;


   rangeLow =
      rates[0].low;


   for(int i = 1;
       i < copied;
       i++)
     {
      if(rates[i].high > rangeHigh)
         rangeHigh =
            rates[i].high;


      if(rates[i].low < rangeLow)
         rangeLow =
            rates[i].low;
     }


   return true;
  }


//+------------------------------------------------------------------+
//| Helper: Calculate Breakout Levels                                |
//+------------------------------------------------------------------+
void CalculateBreakoutLevels()
  {
   // ===============================================================
   // 1. GET ATR
   // ===============================================================

   double atr[1];


   ResetLastError();


   int copied =
      CopyBuffer(
         h_ATR,
         0,
         1,
         1,
         atr
      );


   if(copied != 1)
     {
      Log(
         "ATR_ERROR",
         "ATR CopyBuffer failed"
         " | Copied=" +
         IntegerToString(copied) +
         " | Error=" +
         IntegerToString(
            GetLastError()
         )
      );


      return;
     }


   if(atr[0] <= 0)
     {
      Log(
         "ATR_ERROR",
         "Invalid ATR=" +
         DoubleToString(
            atr[0],
            _Digits
         )
      );


      return;
     }


   // ===============================================================
   // 2. ATR BUFFER
   // ===============================================================

   atrBuffer =
      atr[0] *
      ATR_Buffer_Mult;


   // ===============================================================
   // 3. ENTRY LEVELS
   // ===============================================================

   buyEntryPrice =
      NormalizeDouble(
         rangeHigh +
         atrBuffer,
         _Digits
      );


   sellEntryPrice =
      NormalizeDouble(
         rangeLow -
         atrBuffer,
         _Digits
      );


   if(buyEntryPrice <=
      sellEntryPrice)
     {
      Log(
         "LEVEL_ERROR",
         "Invalid breakout levels."
      );


      return;
     }


   entryLevelsReady =
      true;


   // ===============================================================
   // 4. DRAW ENTRY LEVELS
   // ===============================================================

   if(Draw_Range)
     {
      DrawBreakoutLevels();
     }


   Log(
      "LEVELS",
      "BREAKOUT LEVELS READY"
      " | ATR=" +
      DoubleToString(atr[0], _Digits) +
      " | ATRBuffer=" +
      DoubleToString(atrBuffer, _Digits) +
      " | BUY=" +
      DoubleToString(buyEntryPrice, _Digits) +
      " | SELL=" +
      DoubleToString(sellEntryPrice, _Digits)
   );


   // ===============================================================
   // IMPORTANT
   //
   // At this point price may ALREADY be outside the breakout level.
   //
   // CheckBreakout() executes immediately on the SAME tick.
   // ===============================================================
  }


//+------------------------------------------------------------------+
//| Helper: Check Breakout                                           |
//+------------------------------------------------------------------+
void CheckBreakout(
   MqlTick &tick
)
  {
   if(dailyTradingEnded)
      return;


   if(!rangeReady ||
      !entryLevelsReady)
      return;


   // ===============================================================
   // FIRST TRADE HAS NOT BEEN TAKEN
   // ===============================================================

   if(!firstTradeOpened)
     {
      // ============================================================
      // BUY BREAKOUT
      //
      // We deliberately use:
      //
      // Ask >= BuyEntryPrice
      //
      // NOT an exact equality.
      //
      // Therefore even if price gaps from:
      //
      // 100 -> 105
      //
      // while BuyLevel = 102,
      // the BUY still executes.
      // ============================================================

      if(tick.ask >=
         buyEntryPrice)
        {
         Log(
            "BREAKOUT",
            "BUY BREAKOUT DETECTED"
            " | Ask=" +
            DoubleToString(tick.ask, _Digits) +
            " | BuyLevel=" +
            DoubleToString(buyEntryPrice, _Digits) +
            " | PreviousAsk=" +
            DoubleToString(previousAsk, _Digits)
         );


         if(ExecuteMarketBuy())
           {
            firstTradeOpened =
               true;


            firstDirection =
               1;


            Log(
               "STATE",
               "FIRST TRADE = BUY"
            );
           }
         else
           {
            // -------------------------------------------------------
            // IMPORTANT:
            //
            // firstTradeOpened remains FALSE.
            //
            // Therefore the EA retries the BUY on the NEXT tick
            // while price remains above the breakout level.
            // -------------------------------------------------------

            Log(
               "RETRY",
               "BUY execution failed. Will retry while Ask remains above breakout."
            );
           }


         return;
        }


      // ============================================================
      // SELL BREAKOUT
      // ============================================================

      if(tick.bid <=
         sellEntryPrice)
        {
         Log(
            "BREAKOUT",
            "SELL BREAKOUT DETECTED"
            " | Bid=" +
            DoubleToString(tick.bid, _Digits) +
            " | SellLevel=" +
            DoubleToString(sellEntryPrice, _Digits) +
            " | PreviousBid=" +
            DoubleToString(previousBid, _Digits)
         );


         if(ExecuteMarketSell())
           {
            firstTradeOpened =
               true;


            firstDirection =
               -1;


            Log(
               "STATE",
               "FIRST TRADE = SELL"
            );
           }
         else
           {
            Log(
               "RETRY",
               "SELL execution failed. Will retry while Bid remains below breakout."
            );
           }


         return;
        }


      return;
     }


   // ===============================================================
   // ONLY FIRST SIDE ALLOWED
   // ===============================================================

   if(!Allow_Both_Sides)
      return;


   // ===============================================================
   // SECOND TRADE ALREADY TAKEN
   // ===============================================================

   if(secondTradeOpened)
      return;


   // ===============================================================
   // FIRST TRADE WAS BUY
   //
   // Wait for complete reversal to SELL LEVEL.
   //
   // BUY SL is also SellEntryPrice.
   // ===============================================================

   if(firstDirection == 1)
     {
      if(tick.bid <=
         sellEntryPrice)
        {
         Log(
            "BREAKOUT",
            "SECOND SIDE SELL DETECTED"
            " | Bid=" +
            DoubleToString(tick.bid, _Digits) +
            " | SellLevel=" +
            DoubleToString(sellEntryPrice, _Digits)
         );


         if(ExecuteMarketSell())
           {
            secondTradeOpened =
               true;


            Log(
               "STATE",
               "SECOND TRADE = SELL"
            );
           }
         else
           {
            Log(
               "RETRY",
               "Second-side SELL failed. Will retry."
            );
           }
        }


      return;
     }


   // ===============================================================
   // FIRST TRADE WAS SELL
   //
   // Wait for complete reversal to BUY LEVEL.
   // ===============================================================

   if(firstDirection == -1)
     {
      if(tick.ask >=
         buyEntryPrice)
        {
         Log(
            "BREAKOUT",
            "SECOND SIDE BUY DETECTED"
            " | Ask=" +
            DoubleToString(tick.ask, _Digits) +
            " | BuyLevel=" +
            DoubleToString(buyEntryPrice, _Digits)
         );


         if(ExecuteMarketBuy())
           {
            secondTradeOpened =
               true;


            Log(
               "STATE",
               "SECOND TRADE = BUY"
            );
           }
         else
           {
            Log(
               "RETRY",
               "Second-side BUY failed. Will retry."
            );
           }
        }
     }
  }


//+------------------------------------------------------------------+
//| Helper: Execute Market Buy                                       |
//+------------------------------------------------------------------+
bool ExecuteMarketBuy()
  {
   MqlTick tick;


   if(!SymbolInfoTick(
         _Symbol,
         tick
      ))
     {
      Log(
         "BUY_ERROR",
         "Unable to obtain current tick."
      );


      return false;
     }


   // ===============================================================
   // BUY ENTRY = CURRENT ASK
   // ===============================================================

   double actualEntry =
      tick.ask;


   // ===============================================================
   // BUY SL = OPPOSITE SELL BREAKOUT LEVEL
   // ===============================================================

   double stopLoss =
      sellEntryPrice;


   if(actualEntry <= stopLoss)
     {
      Log(
         "BUY_ERROR",
         "Invalid BUY setup"
         " | Entry=" +
         DoubleToString(actualEntry, _Digits) +
         " | SL=" +
         DoubleToString(stopLoss, _Digits)
      );


      return false;
     }


   // ===============================================================
   // LOT SIZE
   // ===============================================================

   double lotSize =
      GetLotSize(
         ORDER_TYPE_BUY,
         actualEntry,
         stopLoss
      );


   if(lotSize <= 0)
     {
      Log(
         "BUY_ERROR",
         "Lot size <= 0."
      );


      return false;
     }


   // ===============================================================
   // CHECK BROKER STOP DISTANCE
   // ===============================================================

   double slDistance =
      actualEntry -
      stopLoss;


   double minimumStopDistance =
      GetMinimumStopDistance();


   if(slDistance <
      minimumStopDistance)
     {
      Log(
         "BUY_ERROR",
         "SL too close"
         " | SLDistance=" +
         DoubleToString(slDistance, _Digits) +
         " | BrokerMinimum=" +
         DoubleToString(minimumStopDistance, _Digits)
      );


      return false;
     }


   // ===============================================================
   // EXECUTE MARKET ORDER
   // ===============================================================

   ResetLastError();


   bool success =
      trade.Buy(
         lotSize,
         _Symbol,
         0.0,
         stopLoss,
         0.0,
         "ORB BUY"
      );


   // ===============================================================
   // IMPORTANT
   //
   // CTrade returning true only means the request structure passed.
   // Check ResultRetcode as well.
   // ===============================================================

   uint retcode =
      trade.ResultRetcode();


   if(!success ||
      !IsSuccessfulTradeRetcode(retcode))
     {
      LogTradeFailure(
         "MARKET BUY FAILED"
      );


      return false;
     }


   if(Log_Trade)
     {
      Log(
         "TRADE",
         "BUY SUCCESS"
         " | CurrentAsk=" +
         DoubleToString(actualEntry, _Digits) +
         " | BreakoutLevel=" +
         DoubleToString(buyEntryPrice, _Digits) +
         " | ExecutedPrice=" +
         DoubleToString(
            trade.ResultPrice(),
            _Digits
         ) +
         " | SL=" +
         DoubleToString(stopLoss, _Digits) +
         " | Lot=" +
         DoubleToString(lotSize, 4) +
         " | Retcode=" +
         IntegerToString(
            (int)retcode
         )
      );
     }


   return true;
  }


//+------------------------------------------------------------------+
//| Helper: Execute Market Sell                                      |
//+------------------------------------------------------------------+
bool ExecuteMarketSell()
  {
   MqlTick tick;


   if(!SymbolInfoTick(
         _Symbol,
         tick
      ))
     {
      Log(
         "SELL_ERROR",
         "Unable to obtain current tick."
      );


      return false;
     }


   // ===============================================================
   // SELL ENTRY = CURRENT BID
   // ===============================================================

   double actualEntry =
      tick.bid;


   // ===============================================================
   // SELL SL = OPPOSITE BUY BREAKOUT LEVEL
   // ===============================================================

   double stopLoss =
      buyEntryPrice;


   if(actualEntry >= stopLoss)
     {
      Log(
         "SELL_ERROR",
         "Invalid SELL setup"
         " | Entry=" +
         DoubleToString(actualEntry, _Digits) +
         " | SL=" +
         DoubleToString(stopLoss, _Digits)
      );


      return false;
     }


   // ===============================================================
   // LOT SIZE
   // ===============================================================

   double lotSize =
      GetLotSize(
         ORDER_TYPE_SELL,
         actualEntry,
         stopLoss
      );


   if(lotSize <= 0)
     {
      Log(
         "SELL_ERROR",
         "Lot size <= 0."
      );


      return false;
     }


   // ===============================================================
   // CHECK BROKER STOP DISTANCE
   // ===============================================================

   double slDistance =
      stopLoss -
      actualEntry;


   double minimumStopDistance =
      GetMinimumStopDistance();


   if(slDistance <
      minimumStopDistance)
     {
      Log(
         "SELL_ERROR",
         "SL too close"
         " | SLDistance=" +
         DoubleToString(slDistance, _Digits) +
         " | BrokerMinimum=" +
         DoubleToString(minimumStopDistance, _Digits)
      );


      return false;
     }


   // ===============================================================
   // EXECUTE MARKET ORDER
   // ===============================================================

   ResetLastError();


   bool success =
      trade.Sell(
         lotSize,
         _Symbol,
         0.0,
         stopLoss,
         0.0,
         "ORB SELL"
      );


   uint retcode =
      trade.ResultRetcode();


   if(!success ||
      !IsSuccessfulTradeRetcode(retcode))
     {
      LogTradeFailure(
         "MARKET SELL FAILED"
      );


      return false;
     }


   if(Log_Trade)
     {
      Log(
         "TRADE",
         "SELL SUCCESS"
         " | CurrentBid=" +
         DoubleToString(actualEntry, _Digits) +
         " | BreakoutLevel=" +
         DoubleToString(sellEntryPrice, _Digits) +
         " | ExecutedPrice=" +
         DoubleToString(
            trade.ResultPrice(),
            _Digits
         ) +
         " | SL=" +
         DoubleToString(stopLoss, _Digits) +
         " | Lot=" +
         DoubleToString(lotSize, 4) +
         " | Retcode=" +
         IntegerToString(
            (int)retcode
         )
      );
     }


   return true;
  }


//+------------------------------------------------------------------+
//| Helper: Get Lot Size                                             |
//+------------------------------------------------------------------+
double GetLotSize(
   ENUM_ORDER_TYPE orderType,
   double entryPrice,
   double stopLoss
)
  {
   // ===============================================================
   // FIXED LOT MODE
   // ===============================================================

   if(Use_Fixed_Lot)
     {
      double lot =
         NormalizeVolume(
            Fixed_Lot_Size
         );


      if(lot <= 0)
        {
         Log(
            "LOT_ERROR",
            "Invalid fixed lot size."
         );


         return 0.0;
        }


      if(Log_Risk)
        {
         Log(
            "LOT",
            "FIXED LOT MODE"
            " | Requested=" +
            DoubleToString(Fixed_Lot_Size, 4) +
            " | FinalLot=" +
            DoubleToString(lot, 4)
         );
        }


      return lot;
     }


   // ===============================================================
   // RISK-BASED MODE
   // ===============================================================

   return CalculateRiskLotSize(
             orderType,
             entryPrice,
             stopLoss
          );
  }


//+------------------------------------------------------------------+
//| Helper: Risk-Based Lot Calculation                               |
//+------------------------------------------------------------------+
double CalculateRiskLotSize(
   ENUM_ORDER_TYPE orderType,
   double entryPrice,
   double stopLoss
)
  {
   if(entryPrice <= 0 ||
      stopLoss <= 0 ||
      Risk_Percent <= 0)
     {
      Log(
         "RISK_ERROR",
         "Invalid risk calculation input."
      );


      return 0.0;
     }


   // ===============================================================
   // 1. ACCOUNT BALANCE
   // ===============================================================

   double balance =
      AccountInfoDouble(
         ACCOUNT_BALANCE
      );


   double riskMoney =
      balance *
      (Risk_Percent / 100.0);


   if(riskMoney <= 0)
      return 0.0;


   // ===============================================================
   // 2. LOSS FOR 1 LOT
   // ===============================================================

   double lossOneLot =
      0.0;


   ResetLastError();


   bool calculationSuccess =
      OrderCalcProfit(
         orderType,
         _Symbol,
         1.0,
         entryPrice,
         stopLoss,
         lossOneLot
      );


   if(!calculationSuccess)
     {
      Log(
         "RISK_ERROR",
         "OrderCalcProfit failed"
         " | Error=" +
         IntegerToString(
            GetLastError()
         )
      );


      return 0.0;
     }


   lossOneLot =
      MathAbs(
         lossOneLot
      );


   if(lossOneLot <= 0)
      return 0.0;


   // ===============================================================
   // 3. CALCULATE RAW LOT
   // ===============================================================

   double rawLot =
      riskMoney /
      lossOneLot;


   // ===============================================================
   // 4. NORMALIZE LOT
   // ===============================================================

   double finalLot =
      NormalizeVolume(
         rawLot
      );


   if(finalLot <= 0)
     {
      Log(
         "RISK_ERROR",
         "Calculated lot below broker minimum"
         " | RawLot=" +
         DoubleToString(rawLot, 6)
      );


      return 0.0;
     }


   if(Log_Risk)
     {
      Log(
         "RISK",
         "RISK LOT MODE"
         " | Balance=" +
         DoubleToString(balance, 2) +
         " | Risk%=" +
         DoubleToString(Risk_Percent, 2) +
         " | RiskMoney=" +
         DoubleToString(riskMoney, 2) +
         " | Entry=" +
         DoubleToString(entryPrice, _Digits) +
         " | SL=" +
         DoubleToString(stopLoss, _Digits) +
         " | Loss1Lot=" +
         DoubleToString(lossOneLot, 2) +
         " | RawLot=" +
         DoubleToString(rawLot, 6) +
         " | FinalLot=" +
         DoubleToString(finalLot, 4)
      );
     }


   return finalLot;
  }


//+------------------------------------------------------------------+
//| Helper: Normalize Volume                                         |
//+------------------------------------------------------------------+
double NormalizeVolume(
   double volume
)
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


   if(minLot <= 0 ||
      maxLot <= 0 ||
      lotStep <= 0)
      return 0.0;


   if(volume < minLot)
      return 0.0;


   if(volume > maxLot)
      volume =
         maxLot;


   volume =
      MathFloor(
         volume /
         lotStep
      ) *
      lotStep;


   return NormalizeDouble(
             volume,
             8
          );
  }


//+------------------------------------------------------------------+
//| Helper: Broker Minimum Stop Distance                             |
//+------------------------------------------------------------------+
double GetMinimumStopDistance()
  {
   long stopsLevel =
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );


   return(
      stopsLevel *
      _Point
   );
  }


//+------------------------------------------------------------------+
//| Helper: Check Trade Retcode                                      |
//+------------------------------------------------------------------+
bool IsSuccessfulTradeRetcode(
   uint retcode
)
  {
   if(retcode ==
      TRADE_RETCODE_DONE)
      return true;


   if(retcode ==
      TRADE_RETCODE_DONE_PARTIAL)
      return true;


   if(retcode ==
      TRADE_RETCODE_PLACED)
      return true;


   return false;
  }


//+------------------------------------------------------------------+
//| Helper: Draw Opening Range                                       |
//+------------------------------------------------------------------+
void DrawOpeningRange(
   datetime startTime,
   datetime endTime
)
  {
   if(rangeHigh <= 0 ||
      rangeLow <= 0)
      return;


   // ===============================================================
   // SHADED RECTANGLE
   // ===============================================================

   if(ObjectFind(
         0,
         rangeRectangleName
      ) < 0)
     {
      ObjectCreate(
         0,
         rangeRectangleName,
         OBJ_RECTANGLE,
         0,
         startTime,
         rangeHigh,
         endTime,
         rangeLow
      );


      ObjectSetInteger(
         0,
         rangeRectangleName,
         OBJPROP_COLOR,
         ColorToARGB(
            Range_Fill_Color,
            (uchar)Range_Fill_Alpha
         )
      );


      ObjectSetInteger(
         0,
         rangeRectangleName,
         OBJPROP_FILL,
         true
      );


      ObjectSetInteger(
         0,
         rangeRectangleName,
         OBJPROP_BACK,
         true
      );


      ObjectSetInteger(
         0,
         rangeRectangleName,
         OBJPROP_SELECTABLE,
         false
      );
     }


   ObjectMove(
      0,
      rangeRectangleName,
      0,
      startTime,
      rangeHigh
   );


   ObjectMove(
      0,
      rangeRectangleName,
      1,
      endTime,
      rangeLow
   );


   // ===============================================================
   // HIGH LINE
   // ===============================================================

   if(ObjectFind(
         0,
         rangeHighLineName
      ) < 0)
     {
      ObjectCreate(
         0,
         rangeHighLineName,
         OBJ_TREND,
         0,
         startTime,
         rangeHigh,
         endTime,
         rangeHigh
      );


      ObjectSetInteger(
         0,
         rangeHighLineName,
         OBJPROP_COLOR,
         Range_High_Color
      );


      ObjectSetInteger(
         0,
         rangeHighLineName,
         OBJPROP_WIDTH,
         Range_Line_Width
      );


      ObjectSetInteger(
         0,
         rangeHighLineName,
         OBJPROP_RAY_RIGHT,
         false
      );


      ObjectSetInteger(
         0,
         rangeHighLineName,
         OBJPROP_SELECTABLE,
         false
      );
     }


   ObjectMove(
      0,
      rangeHighLineName,
      0,
      startTime,
      rangeHigh
   );


   ObjectMove(
      0,
      rangeHighLineName,
      1,
      endTime,
      rangeHigh
   );


   // ===============================================================
   // LOW LINE
   // ===============================================================

   if(ObjectFind(
         0,
         rangeLowLineName
      ) < 0)
     {
      ObjectCreate(
         0,
         rangeLowLineName,
         OBJ_TREND,
         0,
         startTime,
         rangeLow,
         endTime,
         rangeLow
      );


      ObjectSetInteger(
         0,
         rangeLowLineName,
         OBJPROP_COLOR,
         Range_Low_Color
      );


      ObjectSetInteger(
         0,
         rangeLowLineName,
         OBJPROP_WIDTH,
         Range_Line_Width
      );


      ObjectSetInteger(
         0,
         rangeLowLineName,
         OBJPROP_RAY_RIGHT,
         false
      );


      ObjectSetInteger(
         0,
         rangeLowLineName,
         OBJPROP_SELECTABLE,
         false
      );
     }


   ObjectMove(
      0,
      rangeLowLineName,
      0,
      startTime,
      rangeLow
   );


   ObjectMove(
      0,
      rangeLowLineName,
      1,
      endTime,
      rangeLow
   );


   ChartRedraw();
  }


//+------------------------------------------------------------------+
//| Helper: Draw Breakout Levels                                     |
//+------------------------------------------------------------------+
void DrawBreakoutLevels()
  {
   datetime rangeEnd =
      GetTodayTime(
         Range_End_Hour,
         Range_End_Minute
      );


   datetime eod =
      GetTodayTime(
         EOD_Hour,
         EOD_Minute
      );


   // ===============================================================
   // BUY BREAKOUT LINE
   // ===============================================================

   if(ObjectFind(
         0,
         buyLevelLineName
      ) < 0)
     {
      ObjectCreate(
         0,
         buyLevelLineName,
         OBJ_TREND,
         0,
         rangeEnd,
         buyEntryPrice,
         eod,
         buyEntryPrice
      );


      ObjectSetInteger(
         0,
         buyLevelLineName,
         OBJPROP_COLOR,
         Range_High_Color
      );


      ObjectSetInteger(
         0,
         buyLevelLineName,
         OBJPROP_STYLE,
         STYLE_DASH
      );


      ObjectSetInteger(
         0,
         buyLevelLineName,
         OBJPROP_WIDTH,
         1
      );


      ObjectSetInteger(
         0,
         buyLevelLineName,
         OBJPROP_RAY_RIGHT,
         false
      );


      ObjectSetInteger(
         0,
         buyLevelLineName,
         OBJPROP_SELECTABLE,
         false
      );
     }


   // ===============================================================
   // SELL BREAKOUT LINE
   // ===============================================================

   if(ObjectFind(
         0,
         sellLevelLineName
      ) < 0)
     {
      ObjectCreate(
         0,
         sellLevelLineName,
         OBJ_TREND,
         0,
         rangeEnd,
         sellEntryPrice,
         eod,
         sellEntryPrice
      );


      ObjectSetInteger(
         0,
         sellLevelLineName,
         OBJPROP_COLOR,
         Range_Low_Color
      );


      ObjectSetInteger(
         0,
         sellLevelLineName,
         OBJPROP_STYLE,
         STYLE_DASH
      );


      ObjectSetInteger(
         0,
         sellLevelLineName,
         OBJPROP_WIDTH,
         1
      );


      ObjectSetInteger(
         0,
         sellLevelLineName,
         OBJPROP_RAY_RIGHT,
         false
      );


      ObjectSetInteger(
         0,
         sellLevelLineName,
         OBJPROP_SELECTABLE,
         false
      );
     }


   ChartRedraw();
  }


//+------------------------------------------------------------------+
//| Helper: Close All EA Positions                                   |
//+------------------------------------------------------------------+
void CloseAllPositions()
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


      ResetLastError();


      bool success =
         trade.PositionClose(
            ticket
         );


      Log(
         "CLOSE",
         "Ticket=" +
         IntegerToString(
            (int)ticket
         ) +
         " | Success=" +
         BoolText(success) +
         " | Retcode=" +
         IntegerToString(
            (int)trade.ResultRetcode()
         ) +
         " | Description=" +
         trade.ResultRetcodeDescription()
      );
     }
  }


//+------------------------------------------------------------------+
//| Helper: Check EOD                                                |
//+------------------------------------------------------------------+
bool IsEOD()
  {
   datetime now =
      TimeCurrent();


   datetime eod =
      GetTodayTime(
         EOD_Hour,
         EOD_Minute
      );


   return(
      now >= eod
   );
  }


//+------------------------------------------------------------------+
//| Helper: Check New Trading Day                                    |
//+------------------------------------------------------------------+
void CheckNewDay()
  {
   MqlDateTime dt;


   TimeToStruct(
      TimeCurrent(),
      dt
   );


   // Also check year so year-end reset works correctly
   if(dt.day_of_year == currentDay &&
      dt.year == currentYear)
      return;


   Log(
      "DAY",
      "NEW TRADING DAY DETECTED."
   );


   // ===============================================================
   // SAFETY CLOSE FROM PREVIOUS DAY
   // ===============================================================

   CloseAllPositions();


   // ===============================================================
   // RESET RANGE
   // ===============================================================

   rangeHigh =
      0.0;


   rangeLow =
      0.0;


   // ===============================================================
   // RESET LEVELS
   // ===============================================================

   buyEntryPrice =
      0.0;


   sellEntryPrice =
      0.0;


   atrBuffer =
      0.0;


   // ===============================================================
   // RESET STATE
   // ===============================================================

   rangeReady =
      false;


   entryLevelsReady =
      false;


   firstTradeOpened =
      false;


   secondTradeOpened =
      false;


   firstDirection =
      0;


   dailyTradingEnded =
      false;


   previousAsk =
      0.0;


   previousBid =
      0.0;


   currentDay =
      dt.day_of_year;


   currentYear =
      dt.year;


   // ===============================================================
   // NEW OBJECT NAMES
   // ===============================================================

   SetObjectNames();


   Log(
      "DAY",
      "DAILY STATE RESET COMPLETE."
   );
  }


//+------------------------------------------------------------------+
//| Helper: Set Daily Object Names                                   |
//+------------------------------------------------------------------+
void SetObjectNames()
  {
   MqlDateTime dt;


   TimeToStruct(
      TimeCurrent(),
      dt
   );


   string dateString =
      IntegerToString(dt.year)
      + "_"
      + IntegerToString(dt.mon)
      + "_"
      + IntegerToString(dt.day);


   string prefix =
      "ORB_"
      + IntegerToString(MagicNumber)
      + "_"
      + dateString;


   rangeRectangleName =
      prefix +
      "_RECT";


   rangeHighLineName =
      prefix +
      "_HIGH";


   rangeLowLineName =
      prefix +
      "_LOW";


   buyLevelLineName =
      prefix +
      "_BUY_LEVEL";


   sellLevelLineName =
      prefix +
      "_SELL_LEVEL";
  }


//+------------------------------------------------------------------+
//| Helper: Get Today's Datetime                                     |
//+------------------------------------------------------------------+
datetime GetTodayTime(
   int hour,
   int minute
)
  {
   MqlDateTime dt;


   TimeToStruct(
      TimeCurrent(),
      dt
   );


   dt.hour =
      hour;


   dt.min =
      minute;


   dt.sec =
      0;


   return(
      StructToTime(dt)
   );
  }


//+------------------------------------------------------------------+
//| Helper: Logger                                                   |
//+------------------------------------------------------------------+
void Log(
   string category,
   string message
)
  {
   if(!Enable_Logs)
      return;


   Print(
      "[ORB][",
      category,
      "] ",
      message
   );
  }


//+------------------------------------------------------------------+
//| Helper: Trade Failure Logger                                     |
//+------------------------------------------------------------------+
void LogTradeFailure(
   string action
)
  {
   Log(
      "TRADE_ERROR",
      action +
      " | Retcode=" +
      IntegerToString(
         (int)trade.ResultRetcode()
      ) +
      " | Description=" +
      trade.ResultRetcodeDescription() +
      " | BrokerComment=" +
      trade.ResultComment() +
      " | LastError=" +
      IntegerToString(
         GetLastError()
      ) +
      " | Bid=" +
      DoubleToString(
         SymbolInfoDouble(
            _Symbol,
            SYMBOL_BID
         ),
         _Digits
      ) +
      " | Ask=" +
      DoubleToString(
         SymbolInfoDouble(
            _Symbol,
            SYMBOL_ASK
         ),
         _Digits
      )
   );
  }


//+------------------------------------------------------------------+
//| Helper: Boolean To String                                        |
//+------------------------------------------------------------------+
string BoolText(
   bool value
)
  {
   if(value)
      return "true";


   return "false";
  }


//+------------------------------------------------------------------+
//| Helper: Time Text                                                |
//+------------------------------------------------------------------+
string TimeText(
   int hour,
   int minute
)
  {
   string hourText =
      IntegerToString(hour);


   string minuteText =
      IntegerToString(minute);


   if(hour < 10)
      hourText =
         "0" +
         hourText;


   if(minute < 10)
      minuteText =
         "0" +
         minuteText;


   return(
      hourText +
      ":" +
      minuteText
   );
  }

//+------------------------------------------------------------------+