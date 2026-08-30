#property copyright "Copyright 2026, Built for God Abhishek"
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade/Trade.mqh>

// --- EA Inputs ---
input ENUM_TIMEFRAMES Timeframe          = PERIOD_M15;   // Trading Timeframe

// --- Strong Candle Entry Parameters ---
input int             Average_Candles    = 10;           // Previous X candles for average size
input double          Size_Multiplier    = 2.0;          // Current candle must be X times average size
input double          Min_Body_Percent   = 60.0;         // Minimum body % of full candle range

// --- ATR Stop Loss Parameters ---
input int             ATR_Period         = 14;           // ATR Period
input double          ATR_SL_Multiplier  = 2.0;          // SL Distance = ATR x Multiplier

// --- Take Profit Parameters ---
input double          TP_Multiplier      = 5.0;          // TP Distance = SL Distance x Multiplier

// --- Trade Settings ---
input int             MagicNumber        = 24681;
input double          LotSize            = 0.1;
input int             SlippagePoints     = 5;

// --- Global Variables ---
CTrade trade;
datetime lastBarTime;

// --- Indicator Handles ---
int h_ATR;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // 1. Check Account Type
   // This strategy requires a HEDGING account because BUY and SELL
   // positions must remain open at the same time.
   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);

   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("ERROR: This EA requires a HEDGING account.");
      return(INIT_FAILED);
     }

   // 2. Create ATR Handle
   h_ATR = iATR(_Symbol, Timeframe, ATR_Period);

   if(h_ATR == INVALID_HANDLE)
     {
      Print("Error creating ATR handle");
      return(INIT_FAILED);
     }

   // 3. Trade Settings
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetAsyncMode(false);

   // 4. Initialize Bar Time
   lastBarTime = iTime(_Symbol, Timeframe, 0);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(h_ATR);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Strategy runs only after a candle has closed
   if(!isNewBar())
      return;

   // --- 1. Check For Existing Hedge Trade ---
   if(DoesMyPositionExist())
      return;

   // --- 2. Check Strong Candle Setup ---
   CheckEntries();
  }

//+------------------------------------------------------------------+
//| Helper: Check Entries                                            |
//+------------------------------------------------------------------+
void CheckEntries()
  {
   // ---------------------------------------------------------------
   // Candle [1] = Just Closed Candle
   // Candle [2] onwards = Previous candles used for average
   // ---------------------------------------------------------------

   double open[1];
   double high[1];
   double low[1];
   double close[1];

   if(CopyOpen(_Symbol, Timeframe, 1, 1, open) != 1)
      return;

   if(CopyHigh(_Symbol, Timeframe, 1, 1, high) != 1)
      return;

   if(CopyLow(_Symbol, Timeframe, 1, 1, low) != 1)
      return;

   if(CopyClose(_Symbol, Timeframe, 1, 1, close) != 1)
      return;

   // --- 1. Calculate Current Candle Size ---
   double currentCandleSize = high[0] - low[0];

   if(currentCandleSize <= 0)
      return;

   // --- 2. Calculate Candle Body ---
   double candleBody = MathAbs(close[0] - open[0]);

   // --- 3. Calculate Body Percentage ---
   double bodyPercent = (candleBody / currentCandleSize) * 100.0;

   // --- 4. Calculate Average Size Of Previous X Candles ---
   double averageCandleSize = GetAverageCandleSize();

   if(averageCandleSize <= 0)
      return;

   // --- 5. Strong Candle Conditions ---
   bool isLargeCandle =
      (currentCandleSize >= averageCandleSize * Size_Multiplier);

   bool hasStrongBody =
      (bodyPercent >= Min_Body_Percent);

   bool strongCandle =
      (isLargeCandle && hasStrongBody);

   if(!strongCandle)
      return;

   // --- 6. Get ATR For Dynamic Stop Loss ---
   double atr[1];

   if(CopyBuffer(h_ATR, 0, 1, 1, atr) != 1)
      return;

   if(atr[0] <= 0)
      return;

   // --- 7. Calculate SL Distance ---
   double slDistance = atr[0] * ATR_SL_Multiplier;

   // --- 8. Calculate TP Distance ---
   double tpDistance = slDistance * TP_Multiplier;

   // --- 9. Open Hedge Trades ---
   OpenHedgeTrades(slDistance, tpDistance);
  }

//+------------------------------------------------------------------+
//| Helper: Open BUY + SELL Hedge                                    |
//+------------------------------------------------------------------+
void OpenHedgeTrades(double slDistance, double tpDistance)
  {
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // ---------------------------------------------------------------
   // BUY POSITION
   // BUY executes at ASK
   // ---------------------------------------------------------------

   double buyEntry = tick.ask;

   double buySL = NormalizeDouble(
                     buyEntry - slDistance,
                     digits
                  );

   double buyTP = NormalizeDouble(
                     buyEntry + tpDistance,
                     digits
                  );

   // ---------------------------------------------------------------
   // SELL POSITION
   // SELL executes at BID
   // ---------------------------------------------------------------

   double sellEntry = tick.bid;

   double sellSL = NormalizeDouble(
                      sellEntry + slDistance,
                      digits
                   );

   double sellTP = NormalizeDouble(
                      sellEntry - tpDistance,
                      digits
                   );

   // --- 1. Open BUY ---
   bool buyOpened = trade.Buy(
                       LotSize,
                       _Symbol,
                       0.0,
                       buySL,
                       buyTP,
                       "Volatility Hedge BUY"
                    );

   if(!buyOpened)
     {
      Print("BUY failed. Error: ",
            trade.ResultRetcode(),
            " ",
            trade.ResultRetcodeDescription());

      return;
     }

   // --- 2. Open SELL ---
   bool sellOpened = trade.Sell(
                        LotSize,
                        _Symbol,
                        0.0,
                        sellSL,
                        sellTP,
                        "Volatility Hedge SELL"
                     );

   if(!sellOpened)
     {
      Print("SELL failed. Error: ",
            trade.ResultRetcode(),
            " ",
            trade.ResultRetcodeDescription());

      // If SELL fails, close BUY so we do not remain directional
      CloseMyPositions();

      return;
     }

   Print(
      "HEDGE OPENED | ",
      "SL Distance: ", DoubleToString(slDistance, digits),
      " | TP Distance: ", DoubleToString(tpDistance, digits)
   );
  }

//+------------------------------------------------------------------+
//| Helper: Calculate Average Candle Size                            |
//+------------------------------------------------------------------+
double GetAverageCandleSize()
  {
   if(Average_Candles <= 0)
      return 0.0;

   double highs[];
   double lows[];

   ArrayResize(highs, Average_Candles);
   ArrayResize(lows, Average_Candles);

   // Start from candle [2]
   // Candle [1] is the signal candle and must NOT be included
   if(CopyHigh(
         _Symbol,
         Timeframe,
         2,
         Average_Candles,
         highs
      ) != Average_Candles)
      return 0.0;

   if(CopyLow(
         _Symbol,
         Timeframe,
         2,
         Average_Candles,
         lows
      ) != Average_Candles)
      return 0.0;

   double totalSize = 0.0;

   for(int i = 0; i < Average_Candles; i++)
     {
      double candleSize = highs[i] - lows[i];

      totalSize += candleSize;
     }

   return totalSize / Average_Candles;
  }

//+------------------------------------------------------------------+
//| Helper: Close All EA Positions                                   |
//+------------------------------------------------------------------+
void CloseMyPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      trade.PositionClose(ticket);
     }
  }

//+------------------------------------------------------------------+
//| Helper: Check New Bar                                            |
//+------------------------------------------------------------------+
bool isNewBar()
  {
   datetime current = iTime(_Symbol, Timeframe, 0);

   if(lastBarTime != current)
     {
      lastBarTime = current;
      return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Helper: Check Open Positions                                     |
//+------------------------------------------------------------------+
bool DoesMyPositionExist()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == MagicNumber)
        {
         return true;
        }
     }

   return false;
  }
//+------------------------------------------------------------------+