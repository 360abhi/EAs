#property copyright "Copyright 2025, Built for User"
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade/Trade.mqh>

// --- EA Inputs ---
input ENUM_TIMEFRAMES Timeframe      = PERIOD_H4;  // Trading Timeframe

// --- Cumulative RSI Entry Parameters ---
input int             RSI_Period     = 2;          // RSI Period
input int             TrendMA_Period = 200;        // Trend Filter MA
input double          Cum_RSI_Buy    = 10.0;       // Buy if (RSI[1] + RSI[2]) < this
input double          Cum_RSI_Sell   = 190.0;      // Sell if (RSI[1] + RSI[2]) > this

// --- Exit 1: MA Exit ---
input bool            Use_Exit_MA    = true;       // Flag: Use MA Exit?
input int             ExitMA_Period  = 5;          // Exit MA Period

// --- Exit 2: RSI Exit ---
input bool            Use_Exit_RSI   = false;      // Flag: Use RSI Target Exit?
input double          Exit_RSI_High  = 70.0;       // Close Buy if RSI > this
input double          Exit_RSI_Low   = 30.0;       // Close Sell if RSI < this

// --- Exit 3: Time Exit ---
input bool            Use_Exit_Time  = false;      // Flag: Use Time/Candle Exit?
input int             Max_Candles    = 5;          // Close trade after this many candles

// --- Trade Settings ---
input int             MagicNumber    = 998877;
input double          LotSize        = 0.1;
input int             SlippagePoints = 5;

// --- Global Variables ---
CTrade trade;
datetime lastBarTime;

// --- Indicator Handles ---
int h_RSI;
int h_TrendMA;
int h_ExitMA;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // 1. RSI Handle
   h_RSI = iRSI(_Symbol, Timeframe, RSI_Period, PRICE_CLOSE);

   // 2. Trend MA Handle
   h_TrendMA = iMA(_Symbol, Timeframe, TrendMA_Period, 0, MODE_SMA, PRICE_CLOSE);

   // 3. Exit MA Handle
   h_ExitMA = iMA(_Symbol, Timeframe, ExitMA_Period, 0, MODE_SMA, PRICE_CLOSE);

   if(h_RSI == INVALID_HANDLE || h_TrendMA == INVALID_HANDLE || h_ExitMA == INVALID_HANDLE)
     {
      Print("Error creating handles");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetAsyncMode(false);
   
   lastBarTime = iTime(_Symbol, Timeframe, 0);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(h_RSI);
   IndicatorRelease(h_TrendMA);
   IndicatorRelease(h_ExitMA);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Run logic only on New Bar
   if(!isNewBar()) return;

   // --- 1. Get Indicator Data ---
   // We need 3 RSI values: [0] (current), [1] (last closed), [2] (2 bars ago)
   double rsi[3];      
   double trendMa[1];  
   double exitMa[1];   
   double close[1];    

   // Copy 3 bars for RSI to compare [1] and [2]
   if(CopyBuffer(h_RSI, 0, 0, 3, rsi) != 3) return; 
   
   if(CopyBuffer(h_TrendMA, 0, 1, 1, trendMa) != 1) return;
   if(CopyBuffer(h_ExitMA, 0, 1, 1, exitMa) != 1) return;
   if(CopyClose(_Symbol, Timeframe, 1, 1, close) != 1) return;

   // --- 2. Check Exits First ---
   CheckExits(close[0], exitMa[0], rsi[1]); 

   // --- 3. Check Entries ---
   // Pass the rsi array to check cumulative logic
   CheckEntries(close[0], trendMa[0], rsi);
  }

//+------------------------------------------------------------------+
//| Helper: Check Entries (Cumulative Logic)                         |
//+------------------------------------------------------------------+
void CheckEntries(double prevClose, double trendMa, double &rsi[])
  {
   if(DoesMyPositionExist()) return; 

   // --- Calculate Cumulative RSI ---
   // rsi[1] is the last closed bar
   // rsi[2] is the bar before that
   double rsi_sum = rsi[1] + rsi[2];

   // --- BUY LOGIC ---
   // 1. Filter: Price > 200 SMA
   bool isUptrend = (prevClose > trendMa);
   
   // 2. Trigger: Sum < 10 (oversold)
   bool isCumulativeOversold = (rsi_sum < Cum_RSI_Buy);
   
   // 3. Momentum: RSI[1] < RSI[2] (falling knife condition)
   bool isFalling = (rsi[1] < rsi[2]);

   if(isUptrend && isCumulativeOversold && isFalling)
     {
      trade.Buy(LotSize, _Symbol, 0.0, 0.0, 0.0, "CumRSI Buy");
     }

   // --- SELL LOGIC ---
   // 1. Filter: Price < 200 SMA
   bool isDowntrend = (prevClose < trendMa);
   
   // 2. Trigger: Sum > 190 (overbought)
   bool isCumulativeOverbought = (rsi_sum > Cum_RSI_Sell);
   
   // 3. Momentum: RSI[1] > RSI[2] (rising rocket condition)
   bool isRising = (rsi[1] > rsi[2]);

   if(isDowntrend && isCumulativeOverbought && isRising)
     {
      trade.Sell(LotSize, _Symbol, 0.0, 0.0, 0.0, "CumRSI Sell");
     }
  }

//+------------------------------------------------------------------+
//| Helper: Check Exits (Multi-Exit Logic)                           |
//+------------------------------------------------------------------+
void CheckExits(double prevClose, double exitMa, double prevRsi)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      bool shouldClose = false;

      // Exit 1: MA Crossover
      if(Use_Exit_MA)
        {
         if(type == POSITION_TYPE_BUY && prevClose > exitMa) shouldClose = true;
         if(type == POSITION_TYPE_SELL && prevClose < exitMa) shouldClose = true;
        }

      // Exit 2: RSI Target
      if(Use_Exit_RSI)
        {
         if(type == POSITION_TYPE_BUY && prevRsi > Exit_RSI_High) shouldClose = true;
         if(type == POSITION_TYPE_SELL && prevRsi < Exit_RSI_Low) shouldClose = true;
        }

      // Exit 3: Time/Candle Limit
      if(Use_Exit_Time)
        {
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         int barsOpen = iBarShift(_Symbol, Timeframe, openTime);
         if(barsOpen >= Max_Candles) shouldClose = true;
        }

      if(shouldClose)
        {
         trade.PositionClose(ticket);
        }
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
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return true;
     }
   return false;
  }