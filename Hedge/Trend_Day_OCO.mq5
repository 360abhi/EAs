#property copyright "Copyright 2025, Built for User"
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade/Trade.mqh>

// --- EA Timeframes ---
input ENUM_TIMEFRAMES ATR_Timeframe       = PERIOD_M15;
input ENUM_TIMEFRAMES Box_Timeframe       = PERIOD_M5;

// --- Daily Compression Filter ---
input bool            Use_NR7             = true;

// --- ATR Compression Parameters ---
input int             FastATR_Period      = 14;
input int             SlowATR_Period      = 50;

input double          Max_ATR_Ratio       = 0.80;
// Require ATR(14) / ATR(50) < this

// --- Opening Range Parameters ---
input int             Box_Start_Hour      = 9;
input int             Box_Start_Minute    = 30;

input int             Box_End_Hour        = 10;
input int             Box_End_Minute      = 0;

input double          Max_Box_ATR         = 0.80;
// Opening Range must be < Fast ATR * this

input double          Entry_Buffer_ATR    = 0.10;
// Entry placed this ATR distance outside box

// --- Exit 1: Break Even ---
input bool            Use_Breakeven       = true;
input double          Breakeven_R         = 1.0;

// --- Exit 2: ATR Trailing Stop ---
input bool            Use_ATR_Trail       = true;
input double          Trail_Start_R       = 2.0;

input int             TrailATR_Period     = 14;
input double          Trail_ATR_Multiplier = 2.0;

// --- Session Settings ---
input int             Cancel_Hour         = 12;
input int             Cancel_Minute       = 0;

input int             Flat_Hour           = 15;
input int             Flat_Minute         = 50;

// NY Time = Broker Server Time + this Offset
input int             NY_Offset_From_Server = -7;

// --- Trade Settings ---
input int             MagicNumber         = 220002;

input bool            Use_Risk_Percent    = true;
input double          Risk_Percent        = 0.25;
input double          LotSize             = 0.10;

input int             SlippagePoints      = 5;

// --- Global Variables ---
CTrade trade;

int currentDay = -1;

bool ordersPlaced = false;

double openingHigh = 0.0;
double openingLow  = 0.0;

double originalRisk = 0.0;
double entryPrice   = 0.0;

// --- Indicator Handles ---
int h_FastATR;
int h_SlowATR;
int h_TrailATR;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // 1. Fast ATR Handle
   h_FastATR =
      iATR(
         _Symbol,
         ATR_Timeframe,
         FastATR_Period
      );

   // 2. Slow ATR Handle
   h_SlowATR =
      iATR(
         _Symbol,
         ATR_Timeframe,
         SlowATR_Period
      );

   // 3. M5 ATR Handle for Trailing Stop
   h_TrailATR =
      iATR(
         _Symbol,
         Box_Timeframe,
         TrailATR_Period
      );

   if(h_FastATR == INVALID_HANDLE ||
      h_SlowATR == INVALID_HANDLE ||
      h_TrailATR == INVALID_HANDLE)
     {
      Print("Error creating ATR handles");
      return(INIT_FAILED);
     }

   // 4. Trade Settings
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetAsyncMode(false);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(h_FastATR);
   IndicatorRelease(h_SlowATR);
   IndicatorRelease(h_TrailATR);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // --- 1. New Day Reset ---
   CheckNewDay();

   // --- 2. Hard End-of-Day Exit ---
   if(IsTimeReached(Flat_Hour, Flat_Minute))
     {
      DeleteMyPendingOrders();
      CloseMyPosition();
      return;
     }

   // --- 3. Manage Open Trade ---
   if(DoesMyPositionExist())
     {
      // OCO:
      // Once one order executes, remove the opposite one.
      DeleteMyPendingOrders();

      ManagePosition();

      return;
     }

   // --- 4. Cancel Unfilled Orders ---
   if(IsTimeReached(Cancel_Hour, Cancel_Minute))
     {
      DeleteMyPendingOrders();
      return;
     }

   // --- 5. Wait Until Opening Box is Complete ---
   if(!IsTimeReached(Box_End_Hour, Box_End_Minute))
      return;

   // --- 6. Check Compression and Deploy OCO ---
   if(!ordersPlaced)
     {
      CheckSetupAndPlaceOrders();
     }
  }

//+------------------------------------------------------------------+
//| Helper: Check Setup and Place Orders                            |
//+------------------------------------------------------------------+
void CheckSetupAndPlaceOrders()
  {
   // ==============================================================
   // FILTER 1: DAILY NR7
   // ==============================================================

   if(Use_NR7)
     {
      if(!IsNR7())
        {
         Print("No Trade: Yesterday was not NR7");

         ordersPlaced = true;
         return;
        }
     }

   // ==============================================================
   // GET ATR VALUES AT THE END OF THE OPENING BOX
   // ==============================================================

   double fastATR =
      GetATRAtBoxEnd(
         h_FastATR
      );

   double slowATR =
      GetATRAtBoxEnd(
         h_SlowATR
      );

   if(fastATR <= 0.0 ||
      slowATR <= 0.0)
      return;

   // ==============================================================
   // FILTER 2: M15 VOLATILITY COMPRESSION
   // ==============================================================

   double atrRatio =
      fastATR /
      slowATR;

   if(atrRatio >= Max_ATR_Ratio)
     {
      Print(
         "No Trade: ATR Compression Failed | Ratio = ",
         atrRatio
      );

      ordersPlaced = true;
      return;
     }

   // ==============================================================
   // BUILD 09:30 - 10:00 OPENING RANGE
   // ==============================================================

   if(!CalculateOpeningBox())
     {
      Print("Could not calculate opening range");
      return;
     }

   double boxRange =
      openingHigh -
      openingLow;

   // ==============================================================
   // FILTER 3: OPENING RANGE COMPRESSION
   // ==============================================================

   if(boxRange >=
      fastATR * Max_Box_ATR)
     {
      Print(
         "No Trade: Opening Range Too Large | Range = ",
         boxRange
      );

      ordersPlaced = true;
      return;
     }

   // ==============================================================
   // CALCULATE ENTRY BUFFER
   // ==============================================================

   double entryBuffer =
      fastATR *
      Entry_Buffer_ATR;

   // ==============================================================
   // OCO ENTRY LEVELS
   // ==============================================================

   double buyEntry =
      openingHigh +
      entryBuffer;

   double sellEntry =
      openingLow -
      entryBuffer;

   // ==============================================================
   // STRUCTURAL STOPS
   // ==============================================================

   double buySL =
      openingLow -
      entryBuffer;

   double sellSL =
      openingHigh +
      entryBuffer;

   // --- Normalize Prices ---
   buyEntry  = NormalizePrice(buyEntry);
   sellEntry = NormalizePrice(sellEntry);

   buySL  = NormalizePrice(buySL);
   sellSL = NormalizePrice(sellSL);

   // ==============================================================
   // DO NOT CHASE A BREAKOUT THAT ALREADY OCCURRED
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

   if(ask >= buyEntry ||
      bid <= sellEntry)
     {
      Print("No Trade: Breakout already occurred before OCO placement");

      ordersPlaced = true;
      return;
     }

   // ==============================================================
   // POSITION SIZE
   // ==============================================================

   double lots =
      CalculateLotSize(
         buyEntry,
         buySL
      );

   if(lots <= 0.0)
     {
      Print("Invalid lot size");

      ordersPlaced = true;
      return;
     }

   // ==============================================================
   // PLACE BUY STOP
   // ==============================================================

   bool buyPlaced =
      trade.BuyStop(
         lots,
         buyEntry,
         _Symbol,
         buySL,
         0.0,
         ORDER_TIME_GTC,
         0,
         "TrendDay OCO Buy"
      );

   if(!buyPlaced)
     {
      Print(
         "Buy Stop Failed: ",
         trade.ResultRetcodeDescription()
      );

      ordersPlaced = true;
      return;
     }

   ulong buyTicket =
      trade.ResultOrder();

   // ==============================================================
   // PLACE SELL STOP
   // ==============================================================

   bool sellPlaced =
      trade.SellStop(
         lots,
         sellEntry,
         _Symbol,
         sellSL,
         0.0,
         ORDER_TIME_GTC,
         0,
         "TrendDay OCO Sell"
      );

   if(!sellPlaced)
     {
      Print(
         "Sell Stop Failed: ",
         trade.ResultRetcodeDescription()
      );

      // OCO incomplete -> remove BUY order.
      trade.OrderDelete(buyTicket);

      ordersPlaced = true;
      return;
     }

   ordersPlaced = true;

   Print(
      "Trend-Day OCO Placed",
      " | Fast ATR = ",
      fastATR,
      " | Slow ATR = ",
      slowATR,
      " | ATR Ratio = ",
      atrRatio,
      " | Opening Range = ",
      boxRange
   );
  }

//+------------------------------------------------------------------+
//| Helper: Manage Position                                         |
//+------------------------------------------------------------------+
void ManagePosition()
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

   double openPrice =
      PositionGetDouble(
         POSITION_PRICE_OPEN
      );

   double currentSL =
      PositionGetDouble(
         POSITION_SL
      );

   double currentTP =
      PositionGetDouble(
         POSITION_TP
      );

   // ==============================================================
   // GET ORIGINAL RISK
   // ==============================================================

   if(originalRisk <= 0.0)
     {
      entryPrice =
         openPrice;

      // Rebuild Opening Box if EA was restarted.
      if(openingHigh <= 0.0 ||
         openingLow <= 0.0)
        {
         CalculateOpeningBox();
        }

      double fastATR =
         GetATRAtBoxEnd(
            h_FastATR
         );

      double buffer =
         fastATR *
         Entry_Buffer_ATR;

      if(type == POSITION_TYPE_BUY)
        {
         double theoreticalSL =
            openingLow -
            buffer;

         originalRisk =
            entryPrice -
            theoreticalSL;
        }

      if(type == POSITION_TYPE_SELL)
        {
         double theoreticalSL =
            openingHigh +
            buffer;

         originalRisk =
            theoreticalSL -
            entryPrice;
        }
     }

   if(originalRisk <= 0.0)
      return;

   // ==============================================================
   // CURRENT PRICE
   // ==============================================================

   double price = 0.0;

   if(type == POSITION_TYPE_BUY)
     {
      price =
         SymbolInfoDouble(
            _Symbol,
            SYMBOL_BID
         );
     }

   if(type == POSITION_TYPE_SELL)
     {
      price =
         SymbolInfoDouble(
            _Symbol,
            SYMBOL_ASK
         );
     }

   // ==============================================================
   // CURRENT PROFIT IN R
   // ==============================================================

   double profitDistance = 0.0;

   if(type == POSITION_TYPE_BUY)
     {
      profitDistance =
         price -
         entryPrice;
     }

   if(type == POSITION_TYPE_SELL)
     {
      profitDistance =
         entryPrice -
         price;
     }

   double currentR =
      profitDistance /
      originalRisk;

   // ==============================================================
   // EXIT 1: MOVE TO BREAK EVEN AT +1R
   // ==============================================================

   if(Use_Breakeven &&
      currentR >= Breakeven_R)
     {
      if(type == POSITION_TYPE_BUY)
        {
         if(currentSL < entryPrice)
           {
            double newSL =
               NormalizePrice(
                  entryPrice
               );

            trade.PositionModify(
               ticket,
               newSL,
               currentTP
            );

            currentSL = newSL;
           }
        }

      if(type == POSITION_TYPE_SELL)
        {
         if(currentSL > entryPrice ||
            currentSL == 0.0)
           {
            double newSL =
               NormalizePrice(
                  entryPrice
               );

            trade.PositionModify(
               ticket,
               newSL,
               currentTP
            );

            currentSL = newSL;
           }
        }
     }

   // ==============================================================
   // EXIT 2: ATR TRAIL AFTER +2R
   // ==============================================================

   if(!Use_ATR_Trail)
      return;

   if(currentR < Trail_Start_R)
      return;

   double trailATR =
      GetLatestClosedATR(
         h_TrailATR
      );

   if(trailATR <= 0.0)
      return;

   double trailDistance =
      trailATR *
      Trail_ATR_Multiplier;

   // --- BUY Trailing Stop ---
   if(type == POSITION_TYPE_BUY)
     {
      double newSL =
         price -
         trailDistance;

      newSL =
         NormalizePrice(newSL);

      // Stop can only move UP
      if(newSL > currentSL &&
         newSL < price)
        {
         trade.PositionModify(
            ticket,
            newSL,
            currentTP
         );
        }
     }

   // --- SELL Trailing Stop ---
   if(type == POSITION_TYPE_SELL)
     {
      double newSL =
         price +
         trailDistance;

      newSL =
         NormalizePrice(newSL);

      // Stop can only move DOWN
      if((newSL < currentSL ||
          currentSL == 0.0) &&
         newSL > price)
        {
         trade.PositionModify(
            ticket,
            newSL,
            currentTP
         );
        }
     }
  }

//+------------------------------------------------------------------+
//| Helper: Calculate Opening Box                                   |
//+------------------------------------------------------------------+
bool CalculateOpeningBox()
  {
   datetime startTime =
      GetServerTimeForNYToday(
         Box_Start_Hour,
         Box_Start_Minute
      );

   datetime endTime =
      GetServerTimeForNYToday(
         Box_End_Hour,
         Box_End_Minute
      );

   // Exclude the candle that STARTS at Box_End_Time.
   endTime -= 1;

   MqlRates rates[];

   int copied =
      CopyRates(
         _Symbol,
         Box_Timeframe,
         startTime,
         endTime,
         rates
      );

   if(copied <= 0)
      return false;

   openingHigh =
      -DBL_MAX;

   openingLow =
      DBL_MAX;

   for(int i = 0; i < copied; i++)
     {
      if(rates[i].high > openingHigh)
         openingHigh =
            rates[i].high;

      if(rates[i].low < openingLow)
         openingLow =
            rates[i].low;
     }

   if(openingHigh <= openingLow)
      return false;

   return true;
  }

//+------------------------------------------------------------------+
//| Helper: Get ATR at Box End                                      |
//+------------------------------------------------------------------+
double GetATRAtBoxEnd(int handle)
  {
   datetime boxEndServer =
      GetServerTimeForNYToday(
         Box_End_Hour,
         Box_End_Minute
      );

   // We want the last M15 candle that CLOSED at Box End.
   datetime previousATRBar =
      boxEndServer -
      PeriodSeconds(
         ATR_Timeframe
      );

   int shift =
      iBarShift(
         _Symbol,
         ATR_Timeframe,
         previousATRBar,
         false
      );

   if(shift < 0)
      return 0.0;

   return GetIndicatorValue(
      handle,
      shift
   );
  }

//+------------------------------------------------------------------+
//| Helper: Latest Closed ATR                                       |
//+------------------------------------------------------------------+
double GetLatestClosedATR(int handle)
  {
   return GetIndicatorValue(
      handle,
      1
   );
  }

//+------------------------------------------------------------------+
//| Helper: Get Indicator Value                                     |
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
      return 0.0;

   return value[0];
  }

//+------------------------------------------------------------------+
//| Helper: NR7                                                     |
//+------------------------------------------------------------------+
bool IsNR7()
  {
   double yesterdayRange =
      iHigh(
         _Symbol,
         PERIOD_D1,
         1
      )
      -
      iLow(
         _Symbol,
         PERIOD_D1,
         1
      );

   if(yesterdayRange <= 0.0)
      return false;

   for(int i = 2; i <= 7; i++)
     {
      double range =
         iHigh(
            _Symbol,
            PERIOD_D1,
            i
         )
         -
         iLow(
            _Symbol,
            PERIOD_D1,
            i
         );

      if(range <= 0.0)
         return false;

      if(yesterdayRange >= range)
         return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Helper: Calculate Lot Size                                      |
//+------------------------------------------------------------------+
double CalculateLotSize(double entryPrice, double stopPrice)
  {
   // --- Fixed Lot Mode ---
   if(!Use_Risk_Percent)
      return NormalizeVolume(LotSize);

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
      Risk_Percent
      /
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
      tickValue =
         SymbolInfoDouble(
            _Symbol,
            SYMBOL_TRADE_TICK_VALUE
         );

   if(tickSize <= 0.0 ||
      tickValue <= 0.0)
      return 0.0;

   double moneyLossPerLot =
      (stopDistance / tickSize)
      *
      tickValue;

   if(moneyLossPerLot <= 0.0)
      return 0.0;

   double lots =
      riskMoney /
      moneyLossPerLot;

   return NormalizeVolume(lots);
  }

//+------------------------------------------------------------------+
//| Helper: Normalize Volume                                        |
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

   if(Use_Risk_Percent &&
      volume < minLot)
      return 0.0;

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
         volume / lotStep
      )
      *
      lotStep;

   return NormalizeDouble(
      volume,
      8
   );
  }

//+------------------------------------------------------------------+
//| Helper: Normalize Price                                         |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
  {
   double tickSize =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_TRADE_TICK_SIZE
      );

   if(tickSize <= 0.0)
      return NormalizeDouble(
         price,
         _Digits
      );

   price =
      MathRound(
         price / tickSize
      )
      *
      tickSize;

   return NormalizeDouble(
      price,
      _Digits
   );
  }

//+------------------------------------------------------------------+
//| Helper: Delete My Pending Orders                                |
//+------------------------------------------------------------------+
void DeleteMyPendingOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket =
         OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if(OrderGetInteger(ORDER_MAGIC) != MagicNumber)
         continue;

      trade.OrderDelete(ticket);
     }
  }

//+------------------------------------------------------------------+
//| Helper: Check Open Position                                     |
//+------------------------------------------------------------------+
bool DoesMyPositionExist()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket =
         PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Helper: Get My Position Ticket                                  |
//+------------------------------------------------------------------+
ulong GetMyPositionTicket()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket =
         PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      return ticket;
     }

   return 0;
  }

//+------------------------------------------------------------------+
//| Helper: Close My Position                                       |
//+------------------------------------------------------------------+
void CloseMyPosition()
  {
   ulong ticket =
      GetMyPositionTicket();

   if(ticket > 0)
      trade.PositionClose(ticket);
  }

//+------------------------------------------------------------------+
//| Helper: Get Server Time for Today's NY Time                     |
//+------------------------------------------------------------------+
datetime GetServerTimeForNYToday(int hour, int minute)
  {
   datetime currentNY =
      TimeCurrent() +
      (NY_Offset_From_Server * 3600);

   MqlDateTime dt;
   TimeToStruct(currentNY, dt);

   dt.hour = hour;
   dt.min  = minute;
   dt.sec  = 0;

   datetime requestedNY =
      StructToTime(dt);

   return requestedNY -
      (NY_Offset_From_Server * 3600);
  }

//+------------------------------------------------------------------+
//| Helper: Check Time                                              |
//+------------------------------------------------------------------+
bool IsTimeReached(int hour, int minute)
  {
   datetime currentNY =
      TimeCurrent() +
      (NY_Offset_From_Server * 3600);

   MqlDateTime dt;
   TimeToStruct(currentNY, dt);

   int currentMinutes =
      dt.hour * 60 +
      dt.min;

   int requestedMinutes =
      hour * 60 +
      minute;

   return currentMinutes >= requestedMinutes;
  }

//+------------------------------------------------------------------+
//| Helper: Reset New Day                                           |
//+------------------------------------------------------------------+
void CheckNewDay()
  {
   datetime currentNY =
      TimeCurrent() +
      (NY_Offset_From_Server * 3600);

   MqlDateTime dt;
   TimeToStruct(currentNY, dt);

   int dayKey =
      dt.year * 1000 +
      dt.day_of_year;

   if(dayKey != currentDay)
     {
      currentDay = dayKey;

      ordersPlaced = false;

      openingHigh = 0.0;
      openingLow  = 0.0;

      originalRisk = 0.0;
      entryPrice   = 0.0;
     }
  }