//+------------------------------------------------------------------+
//|                                                   TurtleFTMO.mq5 |
//|                                                                  |
//|  Strategy : "The Original Turtle Trading Rules" (Richard Dennis  |
//|             & William Eckhardt, 1983; rules published for free   |
//|             by Curtis Faith in 2003). Donchian-channel breakout, |
//|             N (ATR) volatility, 2N stop, fixed-fraction sizing.  |
//|                                                                  |
//|  System 1 : enter on a 20-bar breakout, exit on a 10-bar         |
//|             opposite breakout. Skip the signal if the previous   |
//|             System-1 breakout was a winner.                      |
//|  System 2 : failsafe - enter on a 55-bar breakout, exit on a     |
//|             20-bar opposite breakout (no skip filter).           |
//|  Stop     : 2N from entry (N = 20-bar Wilder average true range).|
//|                                                                  |
//|  FTMO layer (additions, not part of the original rules):         |
//|   - fixed % risk per trade (default 0.5%) incl. commission       |
//|   - daily-loss guard + pre-trade daily risk budget               |
//|   - max-loss guard (static or trailing, per FTMO program)        |
//|   - profit-target lock (stop trading once the target is hit)     |
//|   - total open-risk cap, Turtle drawdown risk reduction          |
//|   - spread / rollover / Friday / news entry filters              |
//|   - optional flat-before-weekend for FTMO Standard accounts      |
//|                                                                  |
//|  One chart runs all symbols (default EURUSD, USDJPY, XAUUSD).    |
//+------------------------------------------------------------------+
#property copyright   "gabriel330407"
#property version     "1.00"
#property description "Original Turtle Trading Rules (System 1 20/10 + System 2 55/20, 2N stop)"
#property description "with an FTMO protection layer. Attach to ONE chart (any symbol, D1)."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum ENUM_FTMO_PRESET
  {
   PRESET_2STEP_CHALLENGE    = 0, // FTMO 2-Step: Challenge (target 10%, daily 5%, max 10%)
   PRESET_2STEP_VERIFICATION = 1, // FTMO 2-Step: Verification (target 5%, daily 5%, max 10%)
   PRESET_2STEP_FUNDED       = 2, // FTMO 2-Step: FTMO Account (no target)
   PRESET_1STEP_CHALLENGE    = 3, // FTMO 1-Step: Challenge (target 10%, daily 3%, trailing max 10%)
   PRESET_1STEP_FUNDED       = 4, // FTMO 1-Step: FTMO Account (no target)
   PRESET_CUSTOM             = 5  // Custom (use the "Custom" inputs)
  };

enum ENUM_DAY_ANCHOR
  {
   ANCHOR_BALANCE    = 0, // Balance at the daily reset (FTMO wording)
   ANCHOR_MAX_BAL_EQ = 1  // Max(balance, equity) at the reset (stricter)
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Instruments ==="
input string          InpSymbols      = "EURUSD,USDJPY,XAUUSD"; // Symbols (comma separated)
input string          InpSymbolSuffix = "";                     // Symbol suffix, if your broker uses one
input ENUM_TIMEFRAMES InpTF           = PERIOD_D1;              // Timeframe (original rules: D1)

input group "=== Turtle rules (original) ==="
input bool   InpUseSystem1  = true; // System 1 (20-bar breakout / 10-bar exit)
input int    InpS1Entry     = 20;   // System 1 entry breakout (bars)
input int    InpS1Exit      = 10;   // System 1 exit breakout (bars)
input bool   InpUseSkipRule = true; // System 1: skip signal if last breakout was a winner
input bool   InpUseSystem2  = true; // System 2 failsafe (55-bar breakout / 20-bar exit)
input int    InpS2Entry     = 55;   // System 2 entry breakout (bars)
input int    InpS2Exit      = 20;   // System 2 exit breakout (bars)
input int    InpNPeriod     = 20;   // N (volatility) period
input double InpStopN       = 2.0;  // Stop distance in N
input bool   InpAllowShort  = true; // Allow short trades
input int    InpMaxUnits    = 1;    // Units per symbol (1 = no pyramiding, original = 4)
input double InpAddEveryN   = 0.5;  // Pyramiding: add a unit every X*N in profit
input int    InpHistoryBars = 300;  // Bars used for N and the skip-rule history

input group "=== Risk ==="
input double InpRiskPct          = 0.5; // Risk per trade (% of balance)
input double InpMaxOpenRiskPct   = 2.0; // Max total open risk across all trades (% of balance)
input bool   InpDDRiskReduction  = true;// Turtle rule: reduce risk while in drawdown
input double InpDDStepPct        = 3.0; // ...for every X% below the initial balance
input double InpDDCutFactor      = 0.8; // ...multiply the risk by this factor
input double InpCommissionPerLot = 5.0; // Round-turn commission per lot (account ccy), for sizing

input group "=== FTMO protection ==="
input ENUM_FTMO_PRESET InpPreset          = PRESET_2STEP_CHALLENGE; // FTMO program / phase
input double           InpInitialBalance  = 0;     // Initial account size (0 = auto-detect)
input double           InpGuardAtPct      = 80;    // Close everything at this % of an FTMO loss limit
input double           InpBudgetAtPct     = 60;    // No new trade if worst case exceeds this % of the daily limit
input bool             InpGuardCloseAll   = true;  // Guards also close manual trades & delete pending orders
input int              InpResetHour       = 1;     // Server hour of the FTMO day reset (midnight CE(S)T)
input ENUM_DAY_ANCHOR  InpDayAnchor       = ANCHOR_BALANCE; // Daily loss reference
input double           InpCustomDailyPct  = 5.0;   // Custom: max daily loss (% of initial)
input double           InpCustomMaxPct    = 10.0;  // Custom: max loss (% of initial)
input bool             InpCustomTrailing  = false; // Custom: max loss trails the highest end-of-day balance
input double           InpCustomTargetPct = 10.0;  // Custom: profit target % (0 = none)

input group "=== Cost & execution filters ==="
input double InpMaxSpreadPctOfStop = 2.0;   // Max spread as % of the stop distance
input int    InpMaxSpreadPoints    = 0;     // Max spread in points (0 = off)
input int    InpNoTradeFrom        = 2330;  // No new entries from (server time HHMM)...
input int    InpNoTradeTo          = 130;   // ...until (server time HHMM) - rollover spreads
input int    InpFridayNoEntryHour  = 20;    // No new entries on Friday from this server hour
input bool   InpCloseBeforeWeekend = false; // Close all on Friday (FTMO Standard funded account)
input int    InpFridayCloseHHMM    = 2230;  // Friday close time (server time HHMM)

input group "=== News filter (live only) ==="
input bool InpUseNewsFilter = true; // Block entries around high-impact news (MT5 calendar)
input int  InpNewsBeforeMin = 15;   // Minutes before the release
input int  InpNewsAfterMin  = 15;   // Minutes after the release

input group "=== Misc ==="
input ulong InpMagic          = 20261000; // Magic number base (System 1 = +1, System 2 = +2)
input int   InpTesterTimerSec = 60;       // Timer period inside the Strategy Tester (seconds)
input bool  InpShowPanel      = true;     // Show the status panel on the chart

//+------------------------------------------------------------------+
//| Types                                                            |
//+------------------------------------------------------------------+
struct SymState
  {
   string            name;
   string            ccyBase;
   string            ccyProfit;
   int               digits;
   bool              ready;
   datetime          barTime;       // open time of the forming bar the levels belong to
   datetime          lastCalcTry;
   double            N;             // N as of the last closed bar
   double            hi1, lo1;      // System 1 entry channel
   double            hi2, lo2;      // System 2 entry channel
   double            xHi1, xLo1;    // System 1 exit channel
   double            xHi2, xLo2;    // System 2 exit channel
   int               vPos;          // virtual System-1 position after the last closed bar
   bool              lastS1Win;     // last System-1 breakout was a winner (skip rule)
   datetime          lastEntryBar;
   datetime          lastEntryTry;
   datetime          lastModifyTry;
   string            note;          // why the last signal was not taken (panel)
  };

struct PosInfo
  {
   int               count;
   int               dir;           // 1 long, -1 short
   int               sys;           // 1 or 2
   double            lastEntry;
   datetime          lastOpen;
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade   g_trade;
SymState g_sym[];
int      g_symCount     = 0;
bool     g_initOk       = false;
bool     g_isTester     = false;
string   g_gvPrefix     = "";

double   g_init         = 0.0;   // initial account size
double   g_dailyPct     = 5.0;   // FTMO limits resolved from the preset
double   g_maxPct       = 10.0;
double   g_targetPct    = 10.0;
bool     g_trailing     = false;
string   g_presetName   = "";

datetime g_dayStart     = 0;     // server time of the current FTMO day reset
double   g_dayRef       = 0.0;   // daily loss reference (balance at the reset)
double   g_hwmEod       = 0.0;   // highest end-of-day balance (trailing max loss)

string   g_status       = "";
int      g_guardCode    = 0;
datetime g_lastCloseTry = 0;
datetime g_lastPanel    = 0;

datetime g_newsTime[];
string   g_newsCcy[];
string   g_newsName[];
datetime g_newsLoadedAt = 0;

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
int IMax(const int a, const int b) { return (a > b) ? a : b; }

string GvName(const string key) { return g_gvPrefix + key; }

int MagicToSys(const long magic)
  {
   if(magic == (long)InpMagic + 1)
      return 1;
   if(magic == (long)InpMagic + 2)
      return 2;
   return 0;
  }

int HHMM(const datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   return d.hour * 100 + d.min;
  }

int DowOf(const datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   return d.day_of_week;
  }

bool InWindow(const int hhmm, const int from, const int to)
  {
   if(from == to)
      return false;
   if(from < to)
      return (hhmm >= from && hhmm < to);
   return (hhmm >= from || hhmm < to);
  }

bool InRollover() { return InWindow(HHMM(TimeCurrent()), InpNoTradeFrom, InpNoTradeTo); }

// Most recent FTMO day reset (server time) at or before t
datetime LastReset(const datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   d.hour = InpResetHour;
   d.min  = 0;
   d.sec  = 0;
   datetime r = StructToTime(d);
   if(r > t)
      r -= 86400;
   return r;
  }

double NormPrice(const string sym, double price)
  {
   double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(ts > 0.0)
      price = MathRound(price / ts) * ts;
   return NormalizeDouble(price, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
  }

// Rounds DOWN to the volume step; 0 if below the broker minimum
double NormLots(const string sym, double lots)
  {
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step <= 0.0)
      step = 0.01;
   lots = MathFloor(lots / step + 1e-9) * step;
   if(lots < vmin - 1e-12)
      return 0.0;
   if(vmax > 0.0 && lots > vmax)
      lots = vmax;
   int dg = (int)MathMax(0.0, MathCeil(-MathLog10(step) - 1e-9));
   return NormalizeDouble(lots, dg);
  }

ulong DeviationPts(const string sym)
  {
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   double sp = (pt > 0.0) ? (SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID)) / pt : 0.0;
   long dev = (long)MathCeil(3.0 * sp);
   if(dev < 10)
      dev = 10;
   return (ulong)dev;
  }

double HighestHigh(const MqlRates &r[], const int end, const int len)
  {
   double v = -DBL_MAX;
   for(int k = end - len; k < end; k++)
      if(k >= 0 && r[k].high > v)
         v = r[k].high;
   return v;
  }

double LowestLow(const MqlRates &r[], const int end, const int len)
  {
   double v = DBL_MAX;
   for(int k = end - len; k < end; k++)
      if(k >= 0 && r[k].low < v)
         v = r[k].low;
   return v;
  }

// Money lost by 1.0 lot from entry to stop (positive number)
double LossPerLot(const string sym, const int dir, const double entry, const double sl)
  {
   double profit = 0.0;
   ENUM_ORDER_TYPE ot = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(OrderCalcProfit(ot, sym, 1.0, entry, sl, profit) && profit < 0.0)
      return -profit;
   double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0.0)
      tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0.0 || ts <= 0.0)
      return 0.0;
   return MathAbs(entry - sl) / ts * tv;
  }

//+------------------------------------------------------------------+
//| Account history (FTMO reference values)                          |
//+------------------------------------------------------------------+
double DealNet(const ulong d)
  {
   return HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) +
          HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_FEE);
  }

// Balance at time t = current balance minus everything booked since t
double BalanceAt(const datetime t)
  {
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(!HistorySelect(t, TimeCurrent() + 86400))
      return bal;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      if((datetime)HistoryDealGetInteger(d, DEAL_TIME) < t)
         continue;
      bal -= DealNet(d);
     }
   return bal;
  }

// Highest balance seen at any daily reset up to 'upTo' (FTMO 1-Step trailing max loss)
double HighestEodBalance(const datetime upTo)
  {
   double best = g_init;
   if(!HistorySelect(0, upTo))
      return best;
   int      total     = HistoryDealsTotal();
   double   bal       = 0.0;
   datetime nextReset = 0;
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      datetime t = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
      while(nextReset != 0 && nextReset <= t)
        {
         if(bal > best)
            best = bal;
         nextReset += 86400;
        }
      bal += DealNet(d);
      if(nextReset == 0)
         nextReset = LastReset(t) + 86400;
     }
   if(nextReset != 0 && nextReset <= upTo && bal > best)
      best = bal;
   return best;
  }

double DetectInitialBalance()
  {
   if(InpInitialBalance > 0.0)
      return InpInitialBalance;
   double dep = 0.0;
   if(HistorySelect(0, TimeCurrent() + 86400))
     {
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0)
            continue;
         if(HistoryDealGetInteger(d, DEAL_TYPE) != DEAL_TYPE_BALANCE)
            continue;
         double p = HistoryDealGetDouble(d, DEAL_PROFIT);
         if(p > 0.0)
            dep += p;
        }
     }
   if(dep > 0.0)
      return dep;
   string gv = GvName("init");
   if(GlobalVariableCheck(gv))
      return GlobalVariableGet(gv);
   double b = AccountInfoDouble(ACCOUNT_BALANCE);
   GlobalVariableSet(gv, b);
   return b;
  }

void UpdateDayAnchor()
  {
   datetime ds = LastReset(TimeCurrent());
   if(ds == g_dayStart)
      return;
   bool rolledLive = (g_dayStart != 0);
   g_dayStart = ds;

   double ref = BalanceAt(ds);
   if(InpDayAnchor == ANCHOR_MAX_BAL_EQ)
     {
      if(rolledLive)
         ref = MathMax(ref, AccountInfoDouble(ACCOUNT_EQUITY));
      string gvD = GvName("dstart");
      string gvR = GvName("dref");
      if(GlobalVariableCheck(gvD) && GlobalVariableCheck(gvR) && (datetime)GlobalVariableGet(gvD) == ds)
         ref = MathMax(ref, GlobalVariableGet(gvR));
      GlobalVariableSet(gvD, (double)ds);
      GlobalVariableSet(gvR, ref);
     }
   g_dayRef = ref;
   g_hwmEod = HighestEodBalance(ds);
   PrintFormat("FTMO day from %s (server) | daily reference %.2f | highest EOD balance %.2f",
               TimeToString(ds), g_dayRef, g_hwmEod);
  }

//+------------------------------------------------------------------+
//| FTMO limits                                                      |
//+------------------------------------------------------------------+
double DailyGuardPct()  { return g_dailyPct * InpGuardAtPct  / 100.0; }
double DailyBudgetPct() { return g_dailyPct * InpBudgetAtPct / 100.0; }
double MaxGuardPct()    { return g_maxPct   * InpGuardAtPct  / 100.0; }

double DailyFloor(const double pctOfInit) { return g_dayRef - g_init * pctOfInit / 100.0; }
double MaxLossBase()                      { return g_trailing ? MathMax(g_init, g_hwmEod) : g_init; }
double MaxFloor(const double pctOfInit)   { return MaxLossBase() - g_init * pctOfInit / 100.0; }

double EffectiveRiskPct()
  {
   double r = InpRiskPct;
   if(InpDDRiskReduction && InpDDStepPct > 0.0 && g_init > 0.0)
     {
      double dd = (g_init - AccountInfoDouble(ACCOUNT_BALANCE)) / g_init * 100.0;
      if(dd > 0.0)
         r *= MathPow(InpDDCutFactor, MathFloor(dd / InpDDStepPct));
     }
   return r;
  }

// worstEq  : equity if every open position hits its stop now
// openRisk : sum of losses (vs. entry) still at risk on positions whose stop is not yet in profit
void OpenRiskStats(double &worstEq, double &openRisk)
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   worstEq  = balance;
   openRisk = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      string sym  = PositionGetString(POSITION_SYMBOL);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      double openPx = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double prof = PositionGetDouble(POSITION_PROFIT);
      double swp  = PositionGetDouble(POSITION_SWAP);
      bool   buy  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double atStop = 0.0;
      bool   known  = false;
      if(sl > 0.0)
         known = OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, sym, vol, openPx, sl, atStop);
      if(!known) // no stop (e.g. a manual trade): assume one more full risk unit from here
         atStop = MathMin(prof, 0.0) - balance * InpRiskPct / 100.0;
      atStop += swp - InpCommissionPerLot * vol;
      worstEq += atStop;
      if(atStop < 0.0)
         openRisk += -atStop;
     }
  }

bool RiskAllows(const double tradeRisk, string &why)
  {
   double worstEq = 0.0, openRisk = 0.0;
   OpenRiskStats(worstEq, openRisk);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(InpMaxOpenRiskPct > 0.0 && openRisk + tradeRisk > balance * InpMaxOpenRiskPct / 100.0)
     {
      why = StringFormat("open-risk cap: %.2f%% + %.2f%% > %.2f%%",
                         openRisk / balance * 100.0, tradeRisk / balance * 100.0, InpMaxOpenRiskPct);
      return false;
     }
   double dFloor = DailyFloor(DailyBudgetPct());
   if(worstEq - tradeRisk < dFloor)
     {
      why = StringFormat("daily budget: worst case %.2f < %.2f", worstEq - tradeRisk, dFloor);
      return false;
     }
   double mFloor = MaxFloor(MaxGuardPct());
   if(worstEq - tradeRisk < mFloor)
     {
      why = StringFormat("max-loss budget: worst case %.2f < %.2f", worstEq - tradeRisk, mFloor);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Closing                                                          |
//+------------------------------------------------------------------+
void ClosePositions(const string symFilter, const bool onlyOurs, const string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      if(symFilter != "" && sym != symFilter)
         continue;
      if(onlyOurs && MagicToSys(PositionGetInteger(POSITION_MAGIC)) == 0)
         continue;
      g_trade.SetDeviationInPoints(DeviationPts(sym));
      g_trade.SetTypeFillingBySymbol(sym);
      if(g_trade.PositionClose(tk))
         PrintFormat("Closed #%I64u %s (%s)", tk, sym, reason);
      else
         PrintFormat("Close #%I64u %s failed (%s): %u %s", tk, sym, reason,
                     g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
     }
  }

void DeletePendingOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk != 0)
         g_trade.OrderDelete(tk);
     }
  }

// Returns true while trading must stop. Closes positions when a guard is hit.
bool CheckGuards()
  {
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   int    code = 0;
   string msg  = "";
   if(eq <= MaxFloor(MaxGuardPct()))
     {
      code = 1;
      msg  = StringFormat("MAX-LOSS GUARD (equity <= %.2f)", MaxFloor(MaxGuardPct()));
     }
   else if(eq <= DailyFloor(DailyGuardPct()))
     {
      code = 2;
      msg  = StringFormat("DAILY-LOSS GUARD until next FTMO day (equity <= %.2f)", DailyFloor(DailyGuardPct()));
     }
   else if(g_targetPct > 0.0 && eq >= g_init * (1.0 + g_targetPct / 100.0))
     {
      code = 3;
      msg  = StringFormat("PROFIT TARGET +%.1f%% reached", g_targetPct);
     }

   if(code == 0)
     {
      g_guardCode = 0;
      return false;
     }
   if(code != g_guardCode)
     {
      PrintFormat("%s | equity %.2f -> closing positions, no new trades", msg, eq);
      g_guardCode = code;
     }
   g_status = "HALTED: " + msg;
   if(TimeCurrent() - g_lastCloseTry >= 5)
     {
      g_lastCloseTry = TimeCurrent();
      ClosePositions("", !InpGuardCloseAll, msg);
      if(InpGuardCloseAll)
         DeletePendingOrders();
     }
   return true;
  }

bool WeekendFlatTime()
  {
   if(!InpCloseBeforeWeekend)
      return false;
   datetime now = TimeCurrent();
   int dow = DowOf(now);
   return ((dow == 5 && HHMM(now) >= InpFridayCloseHHMM) || dow == 6 || dow == 0);
  }

//+------------------------------------------------------------------+
//| News (MT5 economic calendar, live only)                          |
//+------------------------------------------------------------------+
void LoadNews(const datetime now)
  {
   g_newsLoadedAt = now;
   ArrayResize(g_newsTime, 0);
   ArrayResize(g_newsCcy, 0);
   ArrayResize(g_newsName, 0);
   string done = "|";
   for(int i = 0; i < g_symCount; i++)
     {
      string ccys[2];
      ccys[0] = g_sym[i].ccyBase;
      ccys[1] = g_sym[i].ccyProfit;
      for(int c = 0; c < 2; c++)
        {
         string ccy = ccys[c];
         if(ccy == "" || StringFind(done, "|" + ccy + "|") >= 0)
            continue;
         done += ccy + "|";
         MqlCalendarValue vals[];
         int cnt = CalendarValueHistory(vals, now - 3600, now + 2 * 86400, NULL, ccy);
         for(int k = 0; k < cnt; k++)
           {
            MqlCalendarEvent ev;
            if(!CalendarEventById(vals[k].event_id, ev))
               continue;
            if(ev.importance != CALENDAR_IMPORTANCE_HIGH)
               continue;
            int m = ArraySize(g_newsTime);
            ArrayResize(g_newsTime, m + 1);
            ArrayResize(g_newsCcy, m + 1);
            ArrayResize(g_newsName, m + 1);
            g_newsTime[m] = vals[k].time;
            g_newsCcy[m]  = ccy;
            g_newsName[m] = ev.name;
           }
        }
     }
  }

bool NewsBlocked(const SymState &s, string &why)
  {
   if(!InpUseNewsFilter || g_isTester)
      return false;
   datetime now = TimeTradeServer();
   if(now - g_newsLoadedAt > 300)
      LoadNews(now);
   int n = ArraySize(g_newsTime);
   for(int k = 0; k < n; k++)
     {
      if(g_newsCcy[k] != s.ccyBase && g_newsCcy[k] != s.ccyProfit)
         continue;
      if(now >= g_newsTime[k] - InpNewsBeforeMin * 60 && now <= g_newsTime[k] + InpNewsAfterMin * 60)
        {
         why = "news: " + g_newsCcy[k] + " " + g_newsName[k];
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Turtle signals                                                   |
//+------------------------------------------------------------------+
// Recomputes N, the channels and the System-1 skip state once per new bar.
bool RefreshSignals(SymState &s)
  {
   datetime t0 = iTime(s.name, InpTF, 0);
   if(t0 <= 0)
      return s.ready;
   datetime now = TimeCurrent();
   if(t0 == s.barTime)
     {
      if(s.ready)
         return true;
      if(now - s.lastCalcTry < 10)
         return false;
     }
   s.lastCalcTry = now;
   s.barTime     = t0;
   s.ready       = false;

   MqlRates r[];
   ArraySetAsSeries(r, false);
   int got     = CopyRates(s.name, InpTF, 1, InpHistoryBars, r); // closed bars, oldest first
   int longest = IMax(IMax(InpS1Entry, InpS1Exit), IMax(InpS2Entry, InpS2Exit));
   if(got < longest + InpNPeriod + 2)
     {
      s.note = "loading history";
      return false;
     }

   //--- N = Wilder average of the true range (as in the original rules)
   double n[];
   ArrayResize(n, got);
   double sum = 0.0;
   for(int k = 0; k < got; k++)
     {
      double tr = r[k].high - r[k].low;
      if(k > 0)
        {
         double pc = r[k - 1].close;
         tr = MathMax(tr, MathMax(MathAbs(r[k].high - pc), MathAbs(r[k].low - pc)));
        }
      if(k < InpNPeriod)
        {
         sum += tr;
         n[k] = sum / (k + 1);
        }
      else
         n[k] = ((InpNPeriod - 1) * n[k - 1] + tr) / InpNPeriod;
     }

   //--- Replay every System-1 breakout (taken or not) to know if the last one won
   int    vPos    = 0;
   double vEntry  = 0.0;
   double vStop   = 0.0;
   bool   lastWin = false;
   int    start   = IMax(InpS1Entry, InpS1Exit) + InpNPeriod;
   for(int k = start; k < got; k++)
     {
      if(vPos == 1)
        {
         double xl = LowestLow(r, k, InpS1Exit);
         if(r[k].low <= vStop)
           {
            lastWin = (MathMin(r[k].open, vStop) > vEntry);
            vPos    = 0;
           }
         else if(r[k].low < xl)
           {
            lastWin = (MathMin(r[k].open, xl) > vEntry);
            vPos    = 0;
           }
         continue;
        }
      if(vPos == -1)
        {
         double xh = HighestHigh(r, k, InpS1Exit);
         if(r[k].high >= vStop)
           {
            lastWin = (MathMax(r[k].open, vStop) < vEntry);
            vPos    = 0;
           }
         else if(r[k].high > xh)
           {
            lastWin = (MathMax(r[k].open, xh) < vEntry);
            vPos    = 0;
           }
         continue;
        }
      double eh = HighestHigh(r, k, InpS1Entry);
      double el = LowestLow(r, k, InpS1Entry);
      bool   up = (r[k].high > eh);
      bool   dn = (r[k].low < el);
      if(up && dn) // outside bar: take the side reached first, approximated by the open
        {
         if(r[k].open > eh)
            dn = false;
         else if(r[k].open < el)
            up = false;
         else if(eh - r[k].open <= r[k].open - el)
            dn = false;
         else
            up = false;
        }
      if(up)
        {
         vPos   = 1;
         vEntry = MathMax(r[k].open, eh);
         vStop  = vEntry - InpStopN * n[k - 1];
        }
      else if(dn)
        {
         vPos   = -1;
         vEntry = MathMin(r[k].open, el);
         vStop  = vEntry + InpStopN * n[k - 1];
        }
     }

   s.N         = n[got - 1];
   s.hi1       = HighestHigh(r, got, InpS1Entry);
   s.lo1       = LowestLow(r, got, InpS1Entry);
   s.hi2       = HighestHigh(r, got, InpS2Entry);
   s.lo2       = LowestLow(r, got, InpS2Entry);
   s.xHi1      = HighestHigh(r, got, InpS1Exit);
   s.xLo1      = LowestLow(r, got, InpS1Exit);
   s.xHi2      = HighestHigh(r, got, InpS2Exit);
   s.xLo2      = LowestLow(r, got, InpS2Exit);
   s.vPos      = vPos;
   s.lastS1Win = lastWin;
   s.ready     = (s.N > 0.0);
   return s.ready;
  }

double ExitLevel(const SymState &s, const int dir, const int sys)
  {
   if(dir > 0)
      return (sys == 1) ? s.xLo1 : s.xLo2;
   return (sys == 1) ? s.xHi1 : s.xHi2;
  }

void ScanPositions(const string sym, PosInfo &p)
  {
   p.count     = 0;
   p.dir       = 0;
   p.sys       = 0;
   p.lastEntry = 0.0;
   p.lastOpen  = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != sym)
         continue;
      int sys = MagicToSys(PositionGetInteger(POSITION_MAGIC));
      if(sys == 0)
         continue;
      p.count++;
      p.dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      p.sys = sys;
      datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
      if(ot >= p.lastOpen)
        {
         p.lastOpen  = ot;
         p.lastEntry = PositionGetDouble(POSITION_PRICE_OPEN);
        }
     }
  }

bool EntryWindowOK(const SymState &s, string &why)
  {
   datetime now = TimeCurrent();
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      why = "Algo Trading is disabled";
      return false;
     }
   if(InWindow(HHMM(now), InpNoTradeFrom, InpNoTradeTo))
     {
      why = "rollover window";
      return false;
     }
   int dow = DowOf(now);
   if(dow == 0 || dow == 6)
     {
      why = "weekend";
      return false;
     }
   if(dow == 5 && HHMM(now) >= InpFridayNoEntryHour * 100)
     {
      why = "Friday evening";
      return false;
     }
   if((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(s.name, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
     {
      why = "symbol not tradable";
      return false;
     }
   MqlTick tick;
   if(!SymbolInfoTick(s.name, tick) || now - tick.time > 300)
     {
      why = "no fresh quotes";
      return false;
     }
   if(NewsBlocked(s, why))
      return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Orders                                                           |
//+------------------------------------------------------------------+
bool OpenUnit(SymState &s, const int dir, const int sys, const bool isAdd, double &fill, string &why)
  {
   fill = 0.0;
   double bid = SymbolInfoDouble(s.name, SYMBOL_BID);
   double ask = SymbolInfoDouble(s.name, SYMBOL_ASK);
   double pt  = SymbolInfoDouble(s.name, SYMBOL_POINT);
   if(bid <= 0.0 || ask <= 0.0 || pt <= 0.0 || s.N <= 0.0)
     {
      why = "no price / N";
      return false;
     }

   //--- cost filters: never pay a spread that is large relative to the risk
   double stopDist = InpStopN * s.N;
   double spread   = ask - bid;
   if(InpMaxSpreadPctOfStop > 0.0 && spread > stopDist * InpMaxSpreadPctOfStop / 100.0)
     {
      why = StringFormat("spread %.0f pts too wide vs stop", spread / pt);
      return false;
     }
   if(InpMaxSpreadPoints > 0 && spread / pt > InpMaxSpreadPoints)
     {
      why = StringFormat("spread %.0f pts > max %d", spread / pt, InpMaxSpreadPoints);
      return false;
     }

   double entry = (dir > 0) ? ask : bid;
   double sl    = NormPrice(s.name, (dir > 0) ? entry - stopDist : entry + stopDist);
   long   lvl   = SymbolInfoInteger(s.name, SYMBOL_TRADE_STOPS_LEVEL);
   if(MathAbs(entry - sl) <= lvl * pt)
     {
      why = "stop inside broker stops level";
      return false;
     }

   //--- position size: risk% of balance / (loss to stop + commission) per lot
   double lossPerLot = LossPerLot(s.name, dir, entry, sl);
   if(lossPerLot <= 0.0)
     {
      why = "cannot value the stop";
      return false;
     }
   lossPerLot += InpCommissionPerLot;
   double riskPct = EffectiveRiskPct();
   double lots    = NormLots(s.name, AccountInfoDouble(ACCOUNT_BALANCE) * riskPct / 100.0 / lossPerLot);
   if(lots <= 0.0)
     {
      why = StringFormat("min lot %.2f would risk more than %.2f%%",
                         SymbolInfoDouble(s.name, SYMBOL_VOLUME_MIN), riskPct);
      return false;
     }
   double tradeRisk = lots * lossPerLot;
   if(!RiskAllows(tradeRisk, why))
      return false;

   ENUM_ORDER_TYPE ot = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double margin = 0.0;
   if(!OrderCalcMargin(ot, s.name, lots, entry, margin))
     {
      why = "margin calculation failed";
      return false;
     }
   if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9)
     {
      why = "not enough free margin";
      return false;
     }

   g_trade.SetExpertMagicNumber(InpMagic + sys);
   g_trade.SetDeviationInPoints(DeviationPts(s.name));
   g_trade.SetTypeFillingBySymbol(s.name);
   string cmt  = StringFormat("TFT S%d%s", sys, isAdd ? " add" : "");
   bool   sent = (dir > 0) ? g_trade.Buy(lots, s.name, 0.0, sl, 0.0, cmt)
                           : g_trade.Sell(lots, s.name, 0.0, sl, 0.0, cmt);
   uint   rc   = g_trade.ResultRetcode();
   if(!sent || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_DONE_PARTIAL && rc != TRADE_RETCODE_PLACED))
     {
      why = StringFormat("order rejected: %u %s", rc, g_trade.ResultRetcodeDescription());
      PrintFormat("%s %s S%d: %s", s.name, (dir > 0) ? "BUY" : "SELL", sys, why);
      return false;
     }
   fill = g_trade.ResultPrice();
   if(fill <= 0.0)
      fill = entry;
   PrintFormat("%s %s S%d%s | lots %.2f | entry %s | SL %s | N %s | risk %.2f (%.2f%% of balance)",
               s.name, (dir > 0) ? "BUY" : "SELL", sys, isAdd ? " (add unit)" : "", lots,
               DoubleToString(fill, s.digits), DoubleToString(sl, s.digits), DoubleToString(s.N, s.digits),
               tradeRisk, tradeRisk / AccountInfoDouble(ACCOUNT_BALANCE) * 100.0);
   return true;
  }

// Moves the server-side stop of all our positions on 'sym' to 'level' if that is tighter.
void MoveStops(const string sym, const int dir, const double level)
  {
   double pt   = SymbolInfoDouble(sym, SYMBOL_POINT);
   double bid  = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask  = SymbolInfoDouble(sym, SYMBOL_ASK);
   long   lvl  = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   long   frz  = SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
   double minD = (double)((lvl > frz) ? lvl : frz) * pt;
   double tgt  = NormPrice(sym, level);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != sym)
         continue;
      if(MagicToSys(PositionGetInteger(POSITION_MAGIC)) == 0)
         continue;
      double cur = PositionGetDouble(POSITION_SL);
      double tp  = PositionGetDouble(POSITION_TP);
      bool better = (dir > 0) ? (cur <= 0.0 || tgt > cur + pt / 2.0)
                              : (cur <= 0.0 || tgt < cur - pt / 2.0);
      if(!better)
         continue;
      bool valid = (dir > 0) ? (bid - tgt > minD) : (tgt - ask > minD);
      if(!valid)
         continue; // too close to price: the channel exit is then handled at market
      if(!g_trade.PositionModify(tk, tgt, tp))
         PrintFormat("%s: SL -> %s failed: %u %s", sym, DoubleToString(tgt, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
                     g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Per-symbol logic                                                 |
//+------------------------------------------------------------------+
void ManageOpen(SymState &s, const PosInfo &p)
  {
   double bid = SymbolInfoDouble(s.name, SYMBOL_BID);
   double ask = SymbolInfoDouble(s.name, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;
   datetime now     = TimeCurrent();
   double   exitLvl = ExitLevel(s, p.dir, p.sys);
   string   why     = "";

   //--- 1) exit channel broken -> close (normally the server stop already did it)
   bool broken = (p.dir > 0) ? (bid <= exitLvl) : (ask >= exitLvl);
   if(broken)
     {
      if(!InRollover() && !NewsBlocked(s, why) && now - s.lastModifyTry >= 5)
        {
         s.lastModifyTry = now;
         ClosePositions(s.name, true, StringFormat("System %d exit channel", p.sys));
        }
      return;
     }

   //--- 2) trail the server stop to the exit channel (and to 2N below the last unit)
   if(now - s.lastModifyTry >= 10)
     {
      s.lastModifyTry = now;
      double level = exitLvl;
      if(p.count > 1)
        {
         double unitStop = p.lastEntry - p.dir * InpStopN * s.N;
         level = (p.dir > 0) ? MathMax(level, unitStop) : MathMin(level, unitStop);
        }
      MoveStops(s.name, p.dir, level);
     }

   //--- 3) pyramiding (off by default)
   if(InpMaxUnits > 1 && p.count < InpMaxUnits && now - s.lastEntryTry >= 30)
     {
      double trig = p.lastEntry + p.dir * InpAddEveryN * s.N;
      bool   hit  = (p.dir > 0) ? (ask >= trig) : (bid <= trig);
      if(hit && EntryWindowOK(s, why))
        {
         s.lastEntryTry = now;
         double fill = 0.0;
         if(OpenUnit(s, p.dir, p.sys, true, fill, why))
            MoveStops(s.name, p.dir, fill - p.dir * InpStopN * s.N);
         else
            s.note = why;
        }
     }
  }

// Remembers (and logs once) why a signal is not being taken
void SetNote(SymState &s, const int dir, const int sys, const string note)
  {
   if(note != s.note)
      PrintFormat("%s %s signal (System %d) not taken - %s", s.name, (dir > 0) ? "LONG" : "SHORT", sys, note);
   s.note = note;
  }

void TryEntry(SymState &s)
  {
   if(s.lastEntryBar == s.barTime)
      return; // at most one new position per symbol per bar
   datetime now = TimeCurrent();
   if(now - s.lastEntryTry < 30)
      return;
   double bid = SymbolInfoDouble(s.name, SYMBOL_BID);
   if(bid <= 0.0)
      return;

   bool s1ok = InpUseSystem1 && s.vPos == 0 && !(InpUseSkipRule && s.lastS1Win);
   int  dir = 0, sys = 0;
   if(s1ok && bid > s.hi1)
     { dir = 1;  sys = 1; }
   else if(s1ok && InpAllowShort && bid < s.lo1)
     { dir = -1; sys = 1; }
   else if(InpUseSystem2 && bid > s.hi2)
     { dir = 1;  sys = 2; }
   else if(InpUseSystem2 && InpAllowShort && bid < s.lo2)
     { dir = -1; sys = 2; }
   if(dir == 0)
     {
      s.note = "";
      return;
     }

   string why = "";
   if(!EntryWindowOK(s, why))
     {
      SetNote(s, dir, sys, "waiting: " + why);
      return;
     }
   s.lastEntryTry = now;
   double fill = 0.0;
   if(OpenUnit(s, dir, sys, false, fill, why))
     {
      s.lastEntryBar = s.barTime;
      s.note = "";
     }
   else
      SetNote(s, dir, sys, "blocked: " + why);
  }

void ManageSymbol(SymState &s)
  {
   if(!RefreshSignals(s))
      return;
   PosInfo p;
   ScanPositions(s.name, p);
   if(p.count > 0)
      ManageOpen(s, p);
   else
      TryEntry(s);
  }

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void DrawPanel()
  {
   if(!InpShowPanel)
      return;
   if(g_isTester && !MQLInfoInteger(MQL_VISUAL_MODE))
      return;
   datetime nowL = TimeLocal();
   if(nowL == g_lastPanel)
      return;
   g_lastPanel = nowL;

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double worstEq = 0.0, openRisk = 0.0;
   OpenRiskStats(worstEq, openRisk);

   string t = "TurtleFTMO 1.00  |  " + g_presetName + "\n";
   t += "Status: " + g_status + "\n";
   t += StringFormat("Initial %.2f   Balance %.2f   Equity %.2f\n", g_init, bal, eq);
   t += StringFormat("FTMO day since %s   reference %.2f\n", TimeToString(g_dayStart), g_dayRef);
   t += StringFormat("Daily  : FTMO floor %.2f | EA close-all %.2f | EA new-trade budget %.2f\n",
                     DailyFloor(g_dailyPct), DailyFloor(DailyGuardPct()), DailyFloor(DailyBudgetPct()));
   t += StringFormat("MaxLoss: FTMO floor %.2f | EA close-all %.2f (%s)\n",
                     MaxFloor(g_maxPct), MaxFloor(MaxGuardPct()), g_trailing ? "trailing" : "static");
   if(g_targetPct > 0.0)
      t += StringFormat("Target : %.2f (+%.1f%%)\n", g_init * (1.0 + g_targetPct / 100.0), g_targetPct);
   t += StringFormat("Risk/trade %.2f%% | open risk %.2f%% | worst-case equity %.2f\n",
                     EffectiveRiskPct(), (bal > 0.0) ? openRisk / bal * 100.0 : 0.0, worstEq);
   t += "------------------------------------------------------------\n";
   for(int i = 0; i < g_symCount; i++)
     {
      if(!g_sym[i].ready)
        {
         t += g_sym[i].name + ": loading data...\n";
         continue;
        }
      int dg = g_sym[i].digits;
      PosInfo p;
      ScanPositions(g_sym[i].name, p);
      string pos = "flat";
      if(p.count > 0)
         pos = StringFormat("%s x%d (S%d) exit %s", (p.dir > 0) ? "LONG" : "SHORT", p.count, p.sys,
                            DoubleToString(ExitLevel(g_sym[i], p.dir, p.sys), dg));
      string s1 = "S1 armed";
      if(!InpUseSystem1)
         s1 = "S1 off";
      else if(g_sym[i].vPos != 0)
         s1 = "S1 in-trade (virtual)";
      else if(InpUseSkipRule && g_sym[i].lastS1Win)
         s1 = "S1 skip (last won)";
      t += StringFormat("%s  N %s | 20: %s / %s | 55: %s / %s | %s | %s %s\n",
                        g_sym[i].name, DoubleToString(g_sym[i].N, dg),
                        DoubleToString(g_sym[i].hi1, dg), DoubleToString(g_sym[i].lo1, dg),
                        DoubleToString(g_sym[i].hi2, dg), DoubleToString(g_sym[i].lo2, dg),
                        s1, pos, g_sym[i].note);
     }
   Comment(t);
  }

//+------------------------------------------------------------------+
//| Main loop                                                        |
//+------------------------------------------------------------------+
void Process()
  {
   if(!g_initOk)
      return;
   UpdateDayAnchor();
   g_status = "TRADING";
   if(!CheckGuards())
     {
      if(WeekendFlatTime())
        {
         g_status = "FLAT FOR THE WEEKEND";
         if(TimeCurrent() - g_lastCloseTry >= 5)
           {
            g_lastCloseTry = TimeCurrent();
            ClosePositions("", true, "weekend close");
           }
        }
      else
        {
         if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
            g_status = "Algo Trading is DISABLED - enable it in the terminal";
         for(int i = 0; i < g_symCount; i++)
            ManageSymbol(g_sym[i]);
        }
     }
   DrawPanel();
  }

//+------------------------------------------------------------------+
//| Setup                                                            |
//+------------------------------------------------------------------+
void InitState(SymState &s, const string nm)
  {
   s.name          = nm;
   s.ccyBase       = SymbolInfoString(nm, SYMBOL_CURRENCY_BASE);
   s.ccyProfit     = SymbolInfoString(nm, SYMBOL_CURRENCY_PROFIT);
   s.digits        = (int)SymbolInfoInteger(nm, SYMBOL_DIGITS);
   s.ready         = false;
   s.barTime       = 0;
   s.lastCalcTry   = 0;
   s.N             = 0.0;
   s.hi1           = 0.0;
   s.lo1           = 0.0;
   s.hi2           = 0.0;
   s.lo2           = 0.0;
   s.xHi1          = 0.0;
   s.xLo1          = 0.0;
   s.xHi2          = 0.0;
   s.xLo2          = 0.0;
   s.vPos          = 0;
   s.lastS1Win     = false;
   s.lastEntryBar  = 0;
   s.lastEntryTry  = 0;
   s.lastModifyTry = 0;
   s.note          = "";
  }

bool ResolvePreset()
  {
   switch(InpPreset)
     {
      case PRESET_2STEP_CHALLENGE:
         g_dailyPct = 5.0; g_maxPct = 10.0; g_trailing = false; g_targetPct = 10.0;
         g_presetName = "FTMO 2-Step Challenge";
         break;
      case PRESET_2STEP_VERIFICATION:
         g_dailyPct = 5.0; g_maxPct = 10.0; g_trailing = false; g_targetPct = 5.0;
         g_presetName = "FTMO 2-Step Verification";
         break;
      case PRESET_2STEP_FUNDED:
         g_dailyPct = 5.0; g_maxPct = 10.0; g_trailing = false; g_targetPct = 0.0;
         g_presetName = "FTMO 2-Step FTMO Account";
         break;
      case PRESET_1STEP_CHALLENGE:
         g_dailyPct = 3.0; g_maxPct = 10.0; g_trailing = true; g_targetPct = 10.0;
         g_presetName = "FTMO 1-Step Challenge";
         break;
      case PRESET_1STEP_FUNDED:
         g_dailyPct = 3.0; g_maxPct = 10.0; g_trailing = true; g_targetPct = 0.0;
         g_presetName = "FTMO 1-Step FTMO Account";
         break;
      default:
         g_dailyPct = InpCustomDailyPct; g_maxPct = InpCustomMaxPct;
         g_trailing = InpCustomTrailing; g_targetPct = InpCustomTargetPct;
         g_presetName = "Custom";
         break;
     }
   return (g_dailyPct > 0.0 && g_maxPct > 0.0 && g_targetPct >= 0.0);
  }

bool ValidateInputs()
  {
   int longest = IMax(IMax(InpS1Entry, InpS1Exit), IMax(InpS2Entry, InpS2Exit));
   if(InpRiskPct <= 0.0 || InpRiskPct > 2.0)
     { Print("Risk per trade must be > 0 and <= 2%"); return false; }
   if(InpS1Entry < 2 || InpS1Exit < 1 || InpS2Entry < 2 || InpS2Exit < 1 || InpNPeriod < 2 || InpStopN <= 0.0)
     { Print("Invalid Turtle periods / stop"); return false; }
   if(InpHistoryBars < longest + InpNPeriod + 50)
     { PrintFormat("History bars must be at least %d", longest + InpNPeriod + 50); return false; }
   if(InpMaxUnits < 1 || InpMaxUnits > 4 || InpAddEveryN <= 0.0)
     { Print("Units per symbol must be 1..4"); return false; }
   if(InpGuardAtPct <= 0.0 || InpGuardAtPct >= 100.0 || InpBudgetAtPct <= 0.0 || InpBudgetAtPct > InpGuardAtPct)
     { Print("Guard % must be in (0,100) and budget % <= guard %"); return false; }
   if(InpResetHour < 0 || InpResetHour > 23)
     { Print("Reset hour must be 0..23"); return false; }
   if(InpDDCutFactor <= 0.0 || InpDDCutFactor > 1.0)
     { Print("Drawdown cut factor must be in (0,1]"); return false; }
   if(!InpUseSystem1 && !InpUseSystem2)
     { Print("Enable at least one Turtle system"); return false; }
   return true;
  }

//+------------------------------------------------------------------+
//| Event handlers                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_isTester = (bool)MQLInfoInteger(MQL_TESTER);
   if(!ValidateInputs() || !ResolvePreset())
      return INIT_PARAMETERS_INCORRECT;

   g_gvPrefix = StringFormat("TFT_%I64d_%I64u_", AccountInfoInteger(ACCOUNT_LOGIN), InpMagic);

   string parts[];
   int cnt = StringSplit(InpSymbols, ',', parts);
   ArrayResize(g_sym, 0);
   g_symCount = 0;
   for(int i = 0; i < cnt; i++)
     {
      string nm = parts[i];
      StringTrimLeft(nm);
      StringTrimRight(nm);
      if(nm == "")
         continue;
      nm += InpSymbolSuffix;
      bool custom = false;
      if(!SymbolExist(nm, custom))
        {
         PrintFormat("Symbol %s not found on this server - skipped", nm);
         continue;
        }
      SymbolSelect(nm, true);
      g_symCount++;
      ArrayResize(g_sym, g_symCount);
      InitState(g_sym[g_symCount - 1], nm);
     }
   if(g_symCount == 0)
     {
      Print("No valid symbols - check InpSymbols / InpSymbolSuffix");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_trade.LogLevel(LOG_LEVEL_ERRORS);
   g_init = DetectInitialBalance();
   if(g_init <= 0.0)
     {
      Print("Could not determine the initial balance - set InpInitialBalance");
      return INIT_PARAMETERS_INCORRECT;
     }
   g_dayStart = 0;
   g_initOk   = true;
   UpdateDayAnchor();

   PrintFormat("TurtleFTMO started | %s | initial %.2f | daily limit %.1f%% (EA guard %.2f%%, budget %.2f%%) | "
               "max loss %.1f%% %s (EA guard %.2f%%) | target %.1f%% | risk %.2f%%/trade | %d symbols",
               g_presetName, g_init, g_dailyPct, DailyGuardPct(), DailyBudgetPct(), g_maxPct,
               g_trailing ? "trailing" : "static", MaxGuardPct(), g_targetPct, InpRiskPct, g_symCount);
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("Note: account is not in hedging mode - pyramided units will merge into one position");

   EventSetTimer(g_isTester ? IMax(1, InpTesterTimerSec) : 1);
   Process();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   Comment("");
  }

void OnTick()  { Process(); }
void OnTimer() { Process(); }
//+------------------------------------------------------------------+
