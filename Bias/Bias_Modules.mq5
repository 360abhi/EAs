//+------------------------------------------------------------------+
//|                                                      BiasLab.mq5 |
//|        Daily Bias Scenario Tester (ICT / PO3 research script)    |
//|                                                                  |
//|  PURPOSE                                                         |
//|  Runs statistical tests on historical data to measure how well   |
//|  different "daily bias" models predict the direction of the      |
//|  daily candle (close vs open). Reports hit-rate and sample size  |
//|  per model AND per scenario, so you can see exactly which        |
//|  scenarios carry edge and which should be skipped.               |
//|                                                                  |
//|  MODELS TESTED                                                   |
//|   T1  Naive continuation  (today = yesterday's direction)        |
//|   T2  PDH/PDL 4-scenario model:                                  |
//|         BULL_CONT  yesterday closed above prior day high         |
//|         BEAR_CONT  yesterday closed below prior day low          |
//|         BULL_REV   yesterday swept prior low, closed inside      |
//|         BEAR_REV   yesterday swept prior high, closed inside     |
//|         (inside/outside days = no bias, counted as skipped)      |
//|   T3  3-candle fade (3 same-direction candles -> predict flip)   |
//|   T4  EMA regime (close vs EMA(N) on D1)                         |
//|   T5  T2 + filters (skip after expansion day > mult*ADR)         |
//|   T6  London sweep of Asian range (intraday M15):                |
//|         sweep Asian LOW first  -> predict BULLISH day            |
//|         sweep Asian HIGH first -> predict BEARISH day            |
//|   T7  Confluence: T2 bias agrees with T6 sweep direction         |
//|   T8  Day-of-week breakdown of T2                                |
//|                                                                  |
//|  USAGE                                                           |
//|   - Attach as a SCRIPT to any chart (symbol doesn't matter if    |
//|     you fill InpSymbols).                                        |
//|   - Results print to Experts log and to CSV in MQL5\Files\.      |
//|   - Session hours are BROKER SERVER TIME. For IC Markets         |
//|     (GMT+2/+3, NY-close aligned): Asia = 01:00-09:00,            |
//|     London window = 09:00-14:00 server is a reasonable default;  |
//|     adjust to your server offset.                                |
//|                                                                  |
//|  NOTES                                                           |
//|   - T6/T7 depend on available M15 history (often much shorter    |
//|     than D1 history). Check the printed N before trusting %.     |
//|   - Rough significance guide: with N=500, a hit rate needs to    |
//|     be > ~54.5% to be distinguishable from a coin flip at 95%.   |
//|     The script prints this threshold per test.                   |
//+------------------------------------------------------------------+
#property copyright  "BiasLab research script"
#property version    "1.00"
#property script_show_inputs
#property strict

//--- inputs
input string InpSymbols        = "";      // Symbols CSV (empty = current chart symbol)
input int    InpLookbackDays   = 2000;    // Max D1 candles to test
input int    InpADRPeriod      = 14;      // ADR period (for expansion filter)
input double InpExpansionMult  = 1.5;     // Skip day if prev range > mult * ADR (T5)
input int    InpEMAPeriod      = 20;      // EMA period for regime test (T4)
input double InpDojiFrac       = 0.10;    // |C-O| < frac*range -> day is neutral (excluded)
input int    InpAsiaStartHour  = 1;       // Asian session start (server time)
input int    InpAsiaEndHour    = 9;       // Asian session end / London open (server time)
input int    InpLondonEndHour  = 14;      // End of London sweep window (server time)
input bool   InpWriteCSV       = true;    // Write BiasLab_Results.csv to MQL5\Files

//--- simple stat container -------------------------------------------------
struct Stat
  {
   string name;
   int    n;
   int    wins;
   int    skipped;
  };

void StatInit(Stat &s, const string nm) { s.name=nm; s.n=0; s.wins=0; s.skipped=0; }
void Tally(Stat &s, const bool win)     { s.n++; if(win) s.wins++; }
double HitPct(const Stat &s)            { return (s.n>0) ? 100.0*s.wins/s.n : 0.0; }

// 95% two-sided threshold above 50% for a fair coin, ~ 50 + 1.96*50/sqrt(N)
double CoinThreshold(const int n)       { return (n>0) ? 50.0 + 1.96*50.0/MathSqrt((double)n) : 100.0; }

//--- direction of a candle: +1 bull, -1 bear, 0 neutral/doji ---------------
int Dir(const MqlRates &r)
  {
   double range = r.high - r.low;
   double body  = r.close - r.open;
   if(range <= 0.0)                       return 0;
   if(MathAbs(body) < InpDojiFrac*range)  return 0;
   return (body > 0) ? 1 : -1;
  }

//--- T2 scenario codes ------------------------------------------------------
#define SC_NONE       0
#define SC_BULL_CONT  1
#define SC_BEAR_CONT  2
#define SC_BULL_REV   3
#define SC_BEAR_REV   4

// classify yesterday (y) vs day-before (p); returns scenario, sets prediction
int ClassifyPDHPDL(const MqlRates &y, const MqlRates &p, int &pred)
  {
   pred = 0;
   bool sweptHigh  = (y.high > p.high);
   bool sweptLow   = (y.low  < p.low);
   bool closeAbove = (y.close > p.high);
   bool closeBelow = (y.close < p.low);

   if(sweptHigh && sweptLow)   return SC_NONE;              // outside day -> ambiguous
   if(closeAbove)              { pred = +1; return SC_BULL_CONT; }
   if(closeBelow)              { pred = -1; return SC_BEAR_CONT; }
   if(sweptLow)                { pred = +1; return SC_BULL_REV;  }
   if(sweptHigh)               { pred = -1; return SC_BEAR_REV;  }
   return SC_NONE;                                          // inside day
  }

//--- ADR of the 'period' candles ENDING at index i (inclusive) --------------
double ADRAt(const MqlRates &rates[], const int i, const int period)
  {
   if(i - period + 1 < 0) return 0.0;
   double sum = 0.0;
   for(int k = i - period + 1; k <= i; k++)
      sum += (rates[k].high - rates[k].low);
   return sum / period;
  }

//--- intraday: first sweep of the Asian range during the London window ------
// returns: +1 predict bullish day (Asian LOW swept first),
//          -1 predict bearish day (Asian HIGH swept first),
//           0 no sweep / no data
int LondonSweepPrediction(const string sym, const datetime dayStart)
  {
   datetime asiaFrom = dayStart + InpAsiaStartHour*3600;
   datetime asiaTo   = dayStart + InpAsiaEndHour*3600;
   datetime ldnTo    = dayStart + InpLondonEndHour*3600;

   MqlRates asia[];
   int na = CopyRates(sym, PERIOD_M15, asiaFrom, asiaTo - 1, asia);
   if(na < 4) return 0;                       // not enough Asian data

   double aHigh = -DBL_MAX, aLow = DBL_MAX;
   for(int k = 0; k < na; k++)
     {
      if(asia[k].high > aHigh) aHigh = asia[k].high;
      if(asia[k].low  < aLow)  aLow  = asia[k].low;
     }

   MqlRates ldn[];
   int nl = CopyRates(sym, PERIOD_M15, asiaTo, ldnTo - 1, ldn);
   if(nl < 1) return 0;

   // scan chronologically for the FIRST side taken
   for(int k = 0; k < nl; k++)
     {
      bool up   = (ldn[k].high > aHigh);
      bool down = (ldn[k].low  < aLow);
      if(up && down)
        {
         // both sides in one M15 bar: use the larger penetration
         double pu = ldn[k].high - aHigh;
         double pd = aLow - ldn[k].low;
         return (pd > pu) ? +1 : -1;
        }
      if(down) return +1;    // sell-side liquidity taken -> expect bullish distribution
      if(up)   return -1;    // buy-side liquidity taken  -> expect bearish distribution
     }
   return 0;                 // London never left the Asian range
  }

//--- pretty print one stat ---------------------------------------------------
void Report(const Stat &s, string &csv)
  {
   string line = StringFormat("%-38s  N=%5d  hit=%6.2f%%  (skip=%d, coin95=%.1f%%)",
                              s.name, s.n, HitPct(s), s.skipped, CoinThreshold(s.n));
   Print(line);
   csv += StringFormat("%s;%d;%.2f;%d;%.2f\n", s.name, s.n, HitPct(s), s.skipped, CoinThreshold(s.n));
  }

//+------------------------------------------------------------------+
//| Run all tests for one symbol                                     |
//+------------------------------------------------------------------+
void RunSymbol(const string sym, string &csv)
  {
   Print("==================================================================");
   Print("BiasLab results for ", sym);
   Print("==================================================================");
   csv += "\nSYMBOL;" + sym + "\nTest;N;Hit%;Skipped;Coin95%\n";

   //--- load D1
   MqlRates d1[];
   int want = InpLookbackDays + InpADRPeriod + InpEMAPeriod + 10;
   int got  = CopyRates(sym, PERIOD_D1, 0, want, d1);
   if(got < 100)
     {
      Print("Not enough D1 data for ", sym, " (got ", got, ")");
      return;
     }
   ArraySetAsSeries(d1, false);              // index 0 = oldest

   //--- EMA on D1 closes (computed manually so it works for any symbol)
   double ema[];
   ArrayResize(ema, got);
   double k = 2.0 / (InpEMAPeriod + 1);
   ema[0] = d1[0].close;
   for(int i = 1; i < got; i++)
      ema[i] = ema[i-1] + k*(d1[i].close - ema[i-1]);

   //--- stats
   Stat t1, t2, t2s[5], t3, t4, t5, t5s[5], t6, t6bull, t6bear, t7, dow[7];
   StatInit(t1, "T1 Naive continuation");
   StatInit(t2, "T2 PDH/PDL 4-scenario (all)");
   StatInit(t2s[SC_BULL_CONT], "T2a  BULL_CONT (close > PDH)");
   StatInit(t2s[SC_BEAR_CONT], "T2b  BEAR_CONT (close < PDL)");
   StatInit(t2s[SC_BULL_REV],  "T2c  BULL_REV  (swept PDL, closed in)");
   StatInit(t2s[SC_BEAR_REV],  "T2d  BEAR_REV  (swept PDH, closed in)");
   StatInit(t3, "T3 3-candle fade");
   StatInit(t4, StringFormat("T4 EMA(%d) regime", InpEMAPeriod));
   StatInit(t5, "T5 T2 + expansion filter (all)");
   StatInit(t5s[SC_BULL_CONT], "T5a  BULL_CONT filtered");
   StatInit(t5s[SC_BEAR_CONT], "T5b  BEAR_CONT filtered");
   StatInit(t5s[SC_BULL_REV],  "T5c  BULL_REV  filtered");
   StatInit(t5s[SC_BEAR_REV],  "T5d  BEAR_REV  filtered");
   StatInit(t6, "T6 London sweep of Asia (all)");
   StatInit(t6bull, "T6a  swept Asia LOW -> bull day");
   StatInit(t6bear, "T6b  swept Asia HIGH -> bear day");
   StatInit(t7, "T7 T2 bias + T6 sweep agree");
   string dnames[7] = {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"};
   for(int d = 0; d < 7; d++) StatInit(dow[d], "T8 T2 on " + dnames[d]);

   int neutralDays = 0;
   int startIdx = MathMax(InpADRPeriod + 2, 3);
   datetime m15Oldest = (datetime)SeriesInfoInteger(sym, PERIOD_M15, SERIES_FIRSTDATE);

   //--- main loop: index i = "today", i-1 = yesterday, i-2 = day before
   for(int i = startIdx; i < got; i++)
     {
      int actual = Dir(d1[i]);
      if(actual == 0) { neutralDays++; continue; }

      //--- T1 naive continuation
      int p1 = Dir(d1[i-1]);
      if(p1 != 0) Tally(t1, p1 == actual); else t1.skipped++;

      //--- T2 PDH/PDL scenarios
      int pred2 = 0;
      int sc = ClassifyPDHPDL(d1[i-1], d1[i-2], pred2);
      if(sc != SC_NONE)
        {
         bool win = (pred2 == actual);
         Tally(t2, win);
         Tally(t2s[sc], win);

         //--- T8 day-of-week (on T2 signals)
         MqlDateTime dt;
         TimeToStruct(d1[i].time, dt);
         Tally(dow[dt.day_of_week], win);
        }
      else t2.skipped++;

      //--- T3 3-candle fade
      int a = Dir(d1[i-1]), b = Dir(d1[i-2]), c = Dir(d1[i-3]);
      if(a != 0 && a == b && b == c) Tally(t3, (-a) == actual);
      else t3.skipped++;

      //--- T4 EMA regime
      int p4 = (d1[i-1].close > ema[i-1]) ? 1 : -1;
      Tally(t4, p4 == actual);

      //--- T5 = T2 gated by expansion filter
      if(sc != SC_NONE)
        {
         double adr    = ADRAt(d1, i-2, InpADRPeriod);   // ADR before yesterday
         double yRange = d1[i-1].high - d1[i-1].low;
         if(adr > 0 && yRange <= InpExpansionMult*adr)
           {
            bool win = (pred2 == actual);
            Tally(t5, win);
            Tally(t5s[sc], win);
           }
         else t5.skipped++;
        }

      //--- T6 / T7 intraday (only where M15 history exists)
      if(m15Oldest > 0 && d1[i].time > m15Oldest + 86400)
        {
         int p6 = LondonSweepPrediction(sym, d1[i].time);
         if(p6 != 0)
           {
            bool win6 = (p6 == actual);
            Tally(t6, win6);
            if(p6 > 0) Tally(t6bull, win6); else Tally(t6bear, win6);

            if(sc != SC_NONE && pred2 == p6) Tally(t7, win6);
           }
         else t6.skipped++;
        }
     }

   //--- report
   Report(t1, csv);
   Report(t2, csv);
   for(int s = SC_BULL_CONT; s <= SC_BEAR_REV; s++) Report(t2s[s], csv);
   Report(t3, csv);
   Report(t4, csv);
   Report(t5, csv);
   for(int s = SC_BULL_CONT; s <= SC_BEAR_REV; s++) Report(t5s[s], csv);
   Report(t6, csv);
   Report(t6bull, csv);
   Report(t6bear, csv);
   Report(t7, csv);
   for(int d = 1; d <= 5; d++) Report(dow[d], csv);
   Print("Neutral/doji days excluded: ", neutralDays,
         "   |  D1 candles analysed: ", got - startIdx);
   Print("Reminder: a hit%% below the coin95 threshold for its N is statistical noise.");
  }

//+------------------------------------------------------------------+
//| Script entry                                                     |
//+------------------------------------------------------------------+
void OnStart()
  {
   string csv = "BiasLab Daily Bias Scenario Tester\nGenerated;" +
                TimeToString(TimeCurrent()) + "\n";

   string syms[];
   int nsym = 0;
   if(StringLen(InpSymbols) > 0)
      nsym = StringSplit(InpSymbols, ',', syms);
   if(nsym <= 0)
     {
      ArrayResize(syms, 1);
      syms[0] = _Symbol;
      nsym = 1;
     }

   for(int s = 0; s < nsym; s++)
     {
      string sym = syms[s];
      StringTrimLeft(sym);
      StringTrimRight(sym);
      if(!SymbolSelect(sym, true))
        {
         Print("Symbol not found: ", sym);
         continue;
        }
      // nudge terminal to load history
      MqlRates warm[];
      CopyRates(sym, PERIOD_D1, 0, 10, warm);
      Sleep(300);
      RunSymbol(sym, csv);
     }

   if(InpWriteCSV)
     {
      int h = FileOpen("BiasLab_Results.csv", FILE_WRITE|FILE_TXT|FILE_ANSI);
      if(h != INVALID_HANDLE)
        {
         FileWriteString(h, csv);
         FileClose(h);
         Print("CSV written to MQL5\\Files\\BiasLab_Results.csv");
        }
      else Print("Could not write CSV, error ", GetLastError());
     }
  }
//+------------------------------------------------------------------+