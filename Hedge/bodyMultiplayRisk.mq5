#property copyright "Copyright 2026, Built for User"
#property link      "https://www.mql5.com"
#property version   "1.10"

#include <Trade/Trade.mqh>

// --- EA Inputs ---
input ENUM_TIMEFRAMES Timeframe          = PERIOD_M15;   // Trading Timeframe

// --- Strong Candle Entry Parameters ---
input int             Average_Candles    = 10;           // Previous X candles for average size
input double          Size_Multiplier    = 2.0;          // Current candle >= X times average size
input double          Min_Body_Percent   = 60.0;         // Minimum candle body percentage

// --- ATR Stop Loss Parameters ---
input int             ATR_Period         = 14;           // ATR Period
input double          ATR_SL_Multiplier  = 1.5;          // SL Distance = ATR x Multiplier

// --- Take Profit Parameters ---
input double          TP_Multiplier      = 4.5;          // TP Distance = SL Distance x Multiplier

// --- Risk Management ---
input double          Risk_Percent       = 2.0;          // TOTAL Risk % if BOTH hedge SLs are hit

// --- Trade Settings ---
input int             MagicNumber        = 24681;
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
   // 1. This strategy requires a HEDGING account
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
   // Logic runs only after candle close
   if(!isNewBar())
      return;

   // Only one hedge setup at a time
   if(DoesMyPositionExist())
      return;

   CheckEntries();
  }

//+------------------------------------------------------------------+
//| Helper: Check Entries                                            |
//+------------------------------------------------------------------+
void CheckEntries()
  {
   // Candle [1] = Just Closed Candle
   // Candle [2+] = Previous candles used for average

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

   // --- 1. Current Candle Size ---
   double currentCandleSize = high[0] - low[0];

   if(currentCandleSize <= 0)
      return;

   // --- 2. Current Candle Body ---
   double candleBody = MathAbs(close[0] - open[0]);

   // --- 3. Body Percentage ---
   double bodyPercent = (candleBody / currentCandleSize) * 100.0;

   // --- 4. Average Previous Candle Size ---
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

   // --- 6. Get ATR ---
   double atr[1];

   if(CopyBuffer(h_ATR, 0, 1, 1, atr) != 1)
      return;

   if(atr[0] <= 0)
      return;

   // --- 7. Dynamic SL Distance ---
   double slDistance = atr[0] * ATR_SL_Multiplier;

   // --- 8. Dynamic TP Distance ---
   double tpDistance = slDistance * TP_Multiplier;

   // --- 9. Calculate Risk-Based Lot Size ---
   double lotSize = CalculateLotSize(slDistance);

   if(lotSize <= 0)
     {
      Print("Invalid Lot Size. Trade skipped.");
      return;
     }

   // --- 10. Open BUY + SELL ---
   OpenHedgeTrades(slDistance, tpDistance, lotSize);
  }

//+------------------------------------------------------------------+
//| Helper: Calculate Risk-Based Lot Size                            |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
  {
   if(slDistance <= 0)
      return 0.0;

   // ---------------------------------------------------------------
   // Risk_Percent = TOTAL hedge risk.
   //
   // Example:
   //
   // Account Balance = $10,000
   // Risk_Percent   = 2%
   //
   // Total Allowed Loss = $200
   //
   // Since we have:
   // BUY  + SELL
   //
   // BUY Risk  = $100
   // SELL Risk = $100
   //
   // If BOTH SLs are hit:
   // Total Loss approximately = $200 = 2%
   // ---------------------------------------------------------------

   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   double totalRiskMoney =
      accountBalance * (Risk_Percent / 100.0);

   double riskPerTrade =
      totalRiskMoney / 2.0;

   // --- Symbol Information ---
   double tickSize =
      SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double tickValue =
      SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   double minLot =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double maxLot =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double lotStep =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(tickSize <= 0 ||
      tickValue <= 0 ||
      lotStep <= 0)
      return 0.0;

   // ---------------------------------------------------------------
   // Calculate loss for 1 lot if SL gets hit
   //
   // Number of ticks = SL Distance / Tick Size
   //
   // Loss for 1 Lot =
   // Number of Ticks x Tick Value
   // ---------------------------------------------------------------

   double numberOfTicks =
      slDistance / tickSize;

   double lossPerLot =
      numberOfTicks * tickValue;

   if(lossPerLot <= 0)
      return 0.0;

   // --- Raw Lot Size ---
   double lotSize =
      riskPerTrade / lossPerLot;

   // --- Adjust Lot Size To Broker Lot Step ---
   lotSize =
      MathFloor(lotSize / lotStep) * lotStep;

   // --- Respect Broker Minimum Lot ---
   if(lotSize < minLot)
     {
      Print(
         "Calculated Lot Size ",
         DoubleToString(lotSize, 4),
         " is below broker minimum ",
         DoubleToString(minLot, 4)
      );

      return 0.0;
     }

   // --- Respect Broker Maximum Lot ---
   if(lotSize > maxLot)
      lotSize = maxLot;

   // --- Normalize Volume ---
   lotSize = NormalizeDouble(lotSize, 8);

   Print(
      "RISK CALCULATION | ",
      "Balance: ", DoubleToString(accountBalance, 2),
      " | Total Risk: ", DoubleToString(totalRiskMoney, 2),
      " | Risk Per Side: ", DoubleToString(riskPerTrade, 2),
      " | SL Distance: ", DoubleToString(slDistance, _Digits),
      " | Lot Size: ", DoubleToString(lotSize, 4)
   );

   return lotSize;
  }

//+------------------------------------------------------------------+
//| Helper: Open BUY + SELL Hedge                                    |
//+------------------------------------------------------------------+
void OpenHedgeTrades(double slDistance,
                     double tpDistance,
                     double lotSize)
  {
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

   int digits =
      (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // ===============================================================
   // BUY POSITION
   // ===============================================================

   double buyEntry = tick.ask;

   double buySL =
      NormalizeDouble(
         buyEntry - slDistance,
         digits
      );

   double buyTP =
      NormalizeDouble(
         buyEntry + tpDistance,
         digits
      );

   // ===============================================================
   // SELL POSITION
   // ===============================================================

   double sellEntry = tick.bid;

   double sellSL =
      NormalizeDouble(
         sellEntry + slDistance,
         digits
      );

   double sellTP =
      NormalizeDouble(
         sellEntry - tpDistance,
         digits
      );

   // --- 1. Open BUY ---
   bool buyOpened =
      trade.Buy(
         lotSize,
         _Symbol,
         0.0,
         buySL,
         buyTP,
         "Volatility Hedge BUY"
      );

   if(!buyOpened)
     {
      Print(
         "BUY failed. Error: ",
         trade.ResultRetcode(),
         " ",
         trade.ResultRetcodeDescription()
      );

      return;
     }

   // --- 2. Open SELL ---
   bool sellOpened =
      trade.Sell(
         lotSize,
         _Symbol,
         0.0,
         sellSL,
         sellTP,
         "Volatility Hedge SELL"
      );

   if(!sellOpened)
     {
      Print(
         "SELL failed. Error: ",
         trade.ResultRetcode(),
         " ",
         trade.ResultRetcodeDescription()
      );

      // Do not remain accidentally directional
      CloseMyPositions();

      return;
     }

   Print(
      "HEDGE OPENED | ",
      "Lots: ", DoubleToString(lotSize, 4),
      " | SL Distance: ", DoubleToString(slDistance, digits),
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

   // Candle [1] is signal candle
   // Average starts from Candle [2]
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
      double candleSize =
         highs[i] - lows[i];

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
   datetime current =
      iTime(_Symbol, Timeframe, 0);

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