//+------------------------------------------------------------------+
//|                                           RangeReentry_EA.mq5    |
//|     Range Breakout & Failed-Breakout Re-entry (Liquidity Sweep)  |
//|                       Multi-asset M5 Expert Advisor for MT5      |
//+------------------------------------------------------------------+
//|  HOW IT WORKS                                                    |
//|  1. For every asset a fixed 4h window (Israel time) is measured  |
//|     on M5 bars -> static Range High / Range Low. No trading.     |
//|  2. The next 20h are the active window. On every CLOSED M5 bar N:|
//|     SELL : an earlier bar of the window closed ABOVE Range High  |
//|            and bar N closes back <= Range High.                  |
//|     BUY  : an earlier bar of the window closed BELOW Range Low   |
//|            and bar N closes back >= Range Low.                   |
//|     -> market order at the open of bar N+1.                      |
//|  3. SL = 1.5 x (High[N] - Low[N]),  TP = 2 x SL distance (1:2).  |
//|  4. Only ONE open position on the whole account at any time.     |
//|  5. FTMO guards: spread filter, Friday 22:30 (Israel) close-out, |
//|     daily loss kill-switch.                                      |
//|                                                                  |
//|  Attach to ONE chart only (any symbol, any timeframe). The EA    |
//|  reads M5 data itself and trades every configured symbol.        |
//+------------------------------------------------------------------+
#property copyright   "gabriel330407"
#property version     "1.00"
#property description "Range Breakout & Failed-Breakout Re-entry (Liquidity Sweep)."
#property description "Multi-asset: EURUSD, XAUUSD, US100, US500. Entries on M5 bar close."
#property description "FTMO guards: max 1 position, spread filter, Friday close-out, daily loss kill-switch."
#property description "Attach to ONE chart only - it trades every configured symbol from there."

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_TIME_MODE
  {
   TIME_MODE_AUTO   = 0, // Auto: server GMT offset + DST rules
   TIME_MODE_MANUAL = 1  // Manual: fixed (Israel - server) hours
  };

enum ENUM_SERVER_DST
  {
   SERVER_DST_US   = 0, // US DST dates (most GMT+2/GMT+3 brokers)
   SERVER_DST_EU   = 1, // EU DST dates
   SERVER_DST_NONE = 2  // No DST (fixed offset all year)
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Asset 1: EURUSD ==="
input bool   InpA1_Enabled    = true;         // Enabled
input string InpA1_Symbol     = "EURUSD";     // Symbol name at your broker
input int    InpA1_RangeStart = 3;            // Range start hour, Israel time (03:00-07:00)
input double InpA1_MaxSpread  = 1.5;          // Max_Spread_Pips (0 = no filter)
input double InpA1_PipSize    = 0.0001;       // Pip size in price units

input group "=== Asset 2: XAUUSD (Gold) ==="
input bool   InpA2_Enabled    = true;         // Enabled
input string InpA2_Symbol     = "XAUUSD";     // Symbol name at your broker
input int    InpA2_RangeStart = 4;            // Range start hour, Israel time (04:00-08:00)
input double InpA2_MaxSpread  = 5.0;          // Max_Spread_Pips (0 = no filter)
input double InpA2_PipSize    = 0.10;         // Pip size in price units ($0.10)

input group "=== Asset 3: US100 (NASDAQ) ==="
input bool   InpA3_Enabled    = true;         // Enabled
input string InpA3_Symbol     = "US100.cash"; // Symbol name at your broker
input int    InpA3_RangeStart = 12;           // Range start hour, Israel time (12:00-16:00)
input double InpA3_MaxSpread  = 3.0;          // Max_Spread_Pips (0 = no filter)
input double InpA3_PipSize    = 1.0;          // Pip size in price units (1 index point)

input group "=== Asset 4: US500 (S&P 500) ==="
input bool   InpA4_Enabled    = true;         // Enabled
input string InpA4_Symbol     = "US500.cash"; // Symbol name at your broker
input int    InpA4_RangeStart = 12;           // Range start hour, Israel time (12:00-16:00)
input double InpA4_MaxSpread  = 1.0;          // Max_Spread_Pips (0 = no filter)
input double InpA4_PipSize    = 1.0;          // Pip size in price units (1 index point)

input group "=== Strategy ==="
input int    InpRangeHours         = 4;       // Range measurement window (hours)
input int    InpTradeHours         = 20;      // Active trading window after the range (hours)
input double InpSLMultiplier       = 1.5;     // SL distance = signal candle height x this
input double InpRewardRisk         = 2.0;     // TP distance = SL distance x this (1:2)
input int    InpMinRangeBars       = 30;      // Min M5 bars needed inside the range window (of 48)
input bool   InpKeepBreakoutOnSkip = true;    // Keep breakout flag when a signal could not be traded
input int    InpEntryRetrySeconds  = 30;      // Seconds to keep retrying entry after bar N+1 opens

input group "=== Risk ==="
input double InpRiskPercent        = 1.0;     // Risk_Percent_Per_Trade (% of balance)
input double InpMaxLots            = 0.0;     // Hard lot cap per trade (0 = broker maximum)
input int    InpSlippagePoints     = 20;      // Max slippage (points)

input group "=== FTMO Protection ==="
input double InpDailyLossPercent   = 3.0;     // Daily_Loss_Limit_Percent (0 = off)
input double InpDailyLossBase      = 0.0;     // % base: 0 = day-start balance, else fixed amount (e.g. 100000)
input int    InpDailyResetHour     = 0;       // Daily reset hour (SERVER time)
input bool   InpFridayClose        = true;    // Friday close-out enabled
input int    InpFridayCloseHour    = 22;      // Friday close-out hour (Israel time)
input int    InpFridayCloseMinute  = 30;      // Friday close-out minute (Israel time)
input bool   InpGuardAllPositions  = true;    // Guards close ALL account positions (false = only this EA)

input group "=== Time Alignment: Israel <-> Broker Server ==="
input ENUM_TIME_MODE  InpTimeMode           = TIME_MODE_AUTO; // Time conversion mode
input int             InpServerGMTOffset    = 2;              // [Auto] Server GMT offset in WINTER (hours)
input ENUM_SERVER_DST InpServerDST          = SERVER_DST_US;  // [Auto] Server DST schedule
input int             InpManualIsraelOffset = 0;              // [Manual] Israel time minus server time (hours)

input group "=== General ==="
input ulong  InpMagic              = 20260923;       // Magic number
input string InpComment            = "RangeReentry"; // Order comment
input bool   InpPushNotify         = true;           // Push notifications to MT5 mobile app
input bool   InpPopupAlerts        = false;          // Pop-up alerts in the terminal
input bool   InpShowPanel          = true;           // Show status panel on the chart
input bool   InpDrawRanges         = true;           // Draw ranges on chart (chart symbol only)

//+------------------------------------------------------------------+
//| Constants & globals                                              |
//+------------------------------------------------------------------+
#define ASSET_COUNT   4
#define HISTORY_BARS  320          // > 24h of M5 bars: always covers the current session
#define OBJ_PREFIX    "RBR_"

CTrade   g_trade;
bool     g_ready          = false;
bool     g_isTester       = false;
bool     g_isOptimization = false;
bool     g_isVisual       = false;
int      g_rangeSec       = 0;
int      g_tradeSec       = 0;

//--- daily loss guard
long     g_dayKey         = -1;
double   g_dayStartRef    = 0.0;
bool     g_dailyHalt      = false;

//--- entry coordination (max 1 position account-wide)
bool     g_entryPlacedThisPass = false;
datetime g_lastEntryTime       = 0;

//--- close-out bookkeeping
datetime g_nextCloseAttempt  = 0;
string   g_lastCloseError    = "";
datetime g_lastCloseErrorLog = 0;
long     g_fridayNoticeDay   = -1;

//--- misc
datetime g_lastPanelUpdate = 0;

//--- DST boundary cache (all values in UTC)
int      g_dstYear = -1;
datetime g_usStart = 0, g_usEnd = 0;
datetime g_euStart = 0, g_euEnd = 0;
datetime g_ilStart = 0, g_ilEnd = 0;

//+------------------------------------------------------------------+
//| Logging / notifications                                          |
//+------------------------------------------------------------------+
void LogMsg(const string msg)
  {
   Print("[RangeReentry] ", msg);
  }

//--- Log + push notification to the MT5 mobile app + optional pop-up
void Notify(const string msg)
  {
   LogMsg(msg);
   if(g_isTester)
      return;
   if(InpPushNotify)
     {
      static bool pushWarned = false;
      if(!SendNotification(StringSubstr("RangeReentry: " + msg, 0, 255)) && !pushWarned)
        {
         pushWarned = true;
         LogMsg("Push notification failed (error " + IntegerToString(GetLastError()) +
                "). Enable it in Tools > Options > Notifications with your MetaQuotes ID.");
        }
     }
   if(InpPopupAlerts)
      Alert("RangeReentry: ", msg);
  }

//+------------------------------------------------------------------+
//| Time helpers                                                     |
//| MT5 bar times are broker SERVER times. Everything in the         |
//| strategy is defined in ISRAEL time, so we convert                |
//| server -> UTC -> Israel (or apply a fixed manual offset).        |
//+------------------------------------------------------------------+
datetime MakeTime(const int year, const int mon, const int day)
  {
   MqlDateTime s;
   ZeroMemory(s);
   s.year = year;
   s.mon  = mon;
   s.day  = day;
   return StructToTime(s);
  }

int DowOf(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return s.day_of_week;           // 0 = Sunday ... 5 = Friday, 6 = Saturday
  }

int YearOf(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return s.year;
  }

//--- n-th (1-based) Sunday of a month, 00:00
datetime NthSunday(const int year, const int mon, const int n)
  {
   datetime first   = MakeTime(year, mon, 1);
   int      toSunday = (7 - DowOf(first)) % 7;
   return first + (toSunday + 7 * (n - 1)) * 86400;
  }

//--- last Sunday of a month, 00:00
datetime LastSunday(const int year, const int mon)
  {
   int      ny      = (mon == 12) ? year + 1 : year;
   int      nm      = (mon == 12) ? 1 : mon + 1;
   datetime lastDay = MakeTime(ny, nm, 1) - 86400;
   return lastDay - DowOf(lastDay) * 86400;
  }

//--- DST switch moments for one year, all expressed in UTC
void EnsureDstCache(const int year)
  {
   if(year == g_dstYear)
      return;
   g_dstYear = year;
//--- USA: 2nd Sunday of March 02:00 EST (07:00 UTC) -> 1st Sunday of November 02:00 EDT (06:00 UTC)
   g_usStart = NthSunday(year, 3, 2) + 7 * 3600;
   g_usEnd   = NthSunday(year, 11, 1) + 6 * 3600;
//--- EU: last Sunday of March 01:00 UTC -> last Sunday of October 01:00 UTC
   g_euStart = LastSunday(year, 3) + 3600;
   g_euEnd   = LastSunday(year, 10) + 3600;
//--- Israel (rules in force since 2013):
//--- Friday before the last Sunday of March 02:00 IST (= 00:00 UTC)
//--- -> last Sunday of October 02:00 IDT (= Saturday 23:00 UTC)
   g_ilStart = LastSunday(year, 3) - 2 * 86400;
   g_ilEnd   = LastSunday(year, 10) - 3600;
  }

datetime ServerToUTC(const datetime serverTime)
  {
   datetime guess = serverTime - InpServerGMTOffset * 3600;
   bool     dst   = false;
   if(InpServerDST != SERVER_DST_NONE)
     {
      EnsureDstCache(YearOf(guess));
      if(InpServerDST == SERVER_DST_US)
         dst = (guess >= g_usStart && guess < g_usEnd);
      else
         dst = (guess >= g_euStart && guess < g_euEnd);
     }
   return serverTime - (InpServerGMTOffset + (dst ? 1 : 0)) * 3600;
  }

bool IsIsraelDST(const datetime utc)
  {
   EnsureDstCache(YearOf(utc));
   return (utc >= g_ilStart && utc < g_ilEnd);
  }

datetime UTCToIsrael(const datetime utc)
  {
   return utc + (IsIsraelDST(utc) ? 3 : 2) * 3600;   // IDT = UTC+3, IST = UTC+2
  }

datetime ServerToIsrael(const datetime serverTime)
  {
   if(InpTimeMode == TIME_MODE_MANUAL)
      return serverTime + InpManualIsraelOffset * 3600;
   return UTCToIsrael(ServerToUTC(serverTime));
  }

//--- Friday at/after the configured close-out time (Israel time)
bool IsAfterFridayCutoff(const datetime nowIL)
  {
   MqlDateTime s;
   TimeToStruct(nowIL, s);
   return (s.day_of_week == 5 &&
           s.hour * 60 + s.min >= InpFridayCloseHour * 60 + InpFridayCloseMinute);
  }

//--- Friday after cut-off, Saturday or Sunday (Israel time): no new entries
bool IsWeekendBlock(const datetime nowIL)
  {
   if(!InpFridayClose)
      return false;
   int dow = DowOf(nowIL);
   if(dow == 6 || dow == 0)
      return true;
   return IsAfterFridayCutoff(nowIL);
  }

//+------------------------------------------------------------------+
//| Trading helpers                                                  |
//+------------------------------------------------------------------+
double RoundToTick(const string sym, const double price)
  {
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   int    digits   = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double p        = price;
   if(tickSize > 0.0)
      p = MathRound(p / tickSize) * tickSize;
   return NormalizeDouble(p, digits);
  }

int VolumeDigits(const double step)
  {
   int    d = 0;
   double s = step;
   while(d < 8 && MathAbs(s - MathRound(s)) > 1e-8)
     {
      s *= 10.0;
      d++;
     }
   return d;
  }

bool IsSuccessRetcode(const uint rc)
  {
   return (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED);
  }

//--- errors that will not go away by retrying within a few seconds
bool IsPermanentRetcode(const uint rc)
  {
   switch(rc)
     {
      case TRADE_RETCODE_INVALID:
      case TRADE_RETCODE_INVALID_VOLUME:
      case TRADE_RETCODE_INVALID_STOPS:
      case TRADE_RETCODE_TRADE_DISABLED:
      case TRADE_RETCODE_NO_MONEY:
      case TRADE_RETCODE_INVALID_FILL:
      case TRADE_RETCODE_LIMIT_VOLUME:
      case TRADE_RETCODE_LIMIT_POSITIONS:
      case TRADE_RETCODE_ONLY_REAL:
         return true;
     }
   return false;
  }

//--- terminal / account / EA permissions
bool TradingPermitted(string &why)
  {
   if(!g_isTester)
     {
      if(TerminalInfoInteger(TERMINAL_CONNECTED) == 0)
        {
         why = "terminal not connected to the trade server";
         return false;
        }
      if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == 0)
        {
         why = "Algo Trading button is OFF in the terminal";
         return false;
        }
     }
   if(MQLInfoInteger(MQL_TRADE_ALLOWED) == 0)
     {
      why = "algo trading not allowed for this EA (EA properties > Common)";
      return false;
     }
   if(AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) == 0)
     {
      why = "trading not allowed on this account";
      return false;
     }
   if(AccountInfoInteger(ACCOUNT_TRADE_EXPERT) == 0)
     {
      why = "EA trading disabled by the broker for this account";
      return false;
     }
   return true;
  }

//--- account-wide gate: spec requires PositionsTotal() == 0
bool EntryGateOpen(string &why)
  {
   if(g_entryPlacedThisPass)
     {
      why = "another asset entered on this pass";
      return false;
     }
   if(PositionsTotal() > 0)
     {
      why = "another position is open (max 1 per account)";
      return false;
     }
//--- short lock so a just-filled position that is not yet listed cannot be doubled
   if(g_lastEntryTime > 0 && (long)(TimeTradeServer() - g_lastEntryTime) < 10)
     {
      why = "post-entry lock";
      return false;
     }
   return TradingPermitted(why);
  }

//+------------------------------------------------------------------+
//| Lot size so that hitting SL loses Risk_Percent_Per_Trade of the  |
//| balance. OrderCalcProfit handles contract size & currency        |
//| conversion for FX, metals and index CFDs alike.                  |
//+------------------------------------------------------------------+
bool CalculateLots(const string sym, const ENUM_ORDER_TYPE orderType, const double entry,
                   const double sl, double &lots, string &why)
  {
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;
   if(riskMoney <= 0.0)
     {
      why = "risk amount is zero";
      return false;
     }

   double pl = 0.0;
   if(!OrderCalcProfit(orderType, sym, 1.0, entry, sl, pl) || pl >= 0.0)
     {
      //--- fallback: tick value
      double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tickValue <= 0.0)
         tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize <= 0.0 || tickValue <= 0.0)
        {
         why = "cannot determine contract value for lot sizing";
         return false;
        }
      pl = -MathAbs(entry - sl) / tickSize * tickValue;
     }
   double lossPerLot = -pl;
   if(lossPerLot <= 0.0)
     {
      why = "invalid SL distance for lot sizing";
      return false;
     }

   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double vMin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vMax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step <= 0.0)
      step = (vMin > 0.0) ? vMin : 0.01;
   if(InpMaxLots > 0.0)
      vMax = MathMin(vMax, InpMaxLots);

   double raw = riskMoney / lossPerLot;
   double vol = MathFloor(raw / step + 1e-7) * step;       // always round DOWN (never over-risk)
   if(vol > vMax)
      vol = MathFloor(vMax / step + 1e-7) * step;
   if(vol < vMin - 1e-9)
     {
      why = StringFormat("risk %.2f %s needs %.4f lots, below broker minimum %.2f",
                         riskMoney, AccountInfoString(ACCOUNT_CURRENCY), raw, vMin);
      return false;
     }

//--- make sure the margin is available
   double margin = 0.0;
   if(OrderCalcMargin(orderType, sym, vol, entry, margin) && margin > 0.0)
     {
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.95;
      if(margin > freeMargin)
        {
         vol = MathFloor(vol * freeMargin / margin / step + 1e-7) * step;
         if(vol < vMin - 1e-9)
           {
            why = "not enough free margin";
            return false;
           }
        }
     }
   lots = NormalizeDouble(vol, VolumeDigits(step));
   return true;
  }

//--- does a position fall under the Friday / kill-switch guards?
bool IsGuardedPosition(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return false;
   if(InpGuardAllPositions)
      return true;
   return (PositionGetInteger(POSITION_MAGIC) == (long)InpMagic);
  }

bool HasGuardedPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && IsGuardedPosition(ticket))
         return true;
     }
   return false;
  }

//--- close guarded positions (throttled; retries every 60s on failure)
void CloseGuardedPositions(const string reason)
  {
   datetime now = TimeTradeServer();
   if(now < g_nextCloseAttempt)
      return;

   int    closed  = 0;
   int    failed  = 0;
   string lastErr = "";
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsGuardedPosition(ticket))
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      g_trade.SetTypeFillingBySymbol(sym);
      bool ok = g_trade.PositionClose(ticket, (ulong)InpSlippagePoints);
      uint rc = g_trade.ResultRetcode();
      if(ok && IsSuccessRetcode(rc))
         closed++;
      else
        {
         failed++;
         lastErr = StringFormat("%s #%I64u: %u %s", sym, ticket, rc, g_trade.ResultRetcodeDescription());
        }
     }

   if(closed > 0)
      Notify(StringFormat("%s: closed %d position(s).", reason, closed));
   if(failed > 0)
     {
      //--- do not flood the journal (e.g. market already closed for the weekend)
      if(lastErr != g_lastCloseError || (long)(now - g_lastCloseErrorLog) >= 900)
        {
         LogMsg(StringFormat("%s: could not close %d position(s), retrying every 60s. Last error: %s",
                             reason, failed, lastErr));
         g_lastCloseError    = lastErr;
         g_lastCloseErrorLog = now;
        }
      g_nextCloseAttempt = now + 60;
     }
   else
      g_nextCloseAttempt = now + 1;
  }

//--- chart helper for the range levels
void DrawLevel(const string name, const datetime t1, const datetime t2, const double price, const color clr)
  {
   ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price))
      return;
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//| CAsset - range, breakout flags and entries for one symbol        |
//+------------------------------------------------------------------+
class CAsset
  {
public:
   //--- configuration
   bool              enabled;
   string            symbol;
   int               rangeStartHour;    // Israel time
   double            maxSpreadPips;
   double            pipSize;

   //--- IsNewBar guard
   datetime          lastBarOpen;       // open time of the newest (forming) M5 bar already handled
   datetime          lastProcessedBar;  // open time of the newest CLOSED M5 bar already evaluated

   //--- current session (range window + active window)
   datetime          sessionStartIL;
   bool              rangeReady;
   bool              rangeFailed;
   double            rangeHigh;
   double            rangeLow;
   int               rangeBars;
   datetime          rangeStartSrv;
   datetime          rangeEndSrv;

   //--- breakout flags (a close outside the range, on bar N-1 or earlier)
   bool              brokeAbove;
   bool              brokeBelow;
   datetime          lastAboveBar;
   datetime          lastBelowBar;

   //--- signal waiting to be executed at the open of bar N+1
   int               pendingDir;        // +1 BUY, -1 SELL, 0 none
   double            pendingHeight;     // High[N] - Low[N]
   datetime          pendingBarTime;    // open time of signal bar N
   datetime          pendingExpiry;
   datetime          pendingNextAttempt;
   string            pendingWait;

   string            lastLog;

                     CAsset(void);
   void              Configure(const bool en, const string sym, const int startHour,
                               const double maxSpread, const double pip);
   void              Update(const bool entriesBlocked, const string blockReason);
   string            StatusLine(const datetime nowIL);

   void              AssetLog(const string msg);
   void              LogOnce(const string msg);
   datetime          SessionStartFor(const datetime il);
   void              StartSession(const datetime sessIL);
   bool              ProcessNewBars(const bool liveMode);
   void              ProcessClosedBar(const MqlRates &rates[], const int k, const bool canTrade);
   void              BuildRange(const MqlRates &rates[], const int k);
   void              EvaluateBar(const MqlRates &bar, const bool canTrade);
   void              CreatePending(const int dir, const MqlRates &bar);
   void              TryPendingEntry(const bool entriesBlocked, const string blockReason);
   void              SetWait(const string key, const string detail);
   void              SkipPending(const string reason);
   void              ApplySkipPolicy(const datetime signalBar);
   void              ConsumeBreakouts(const datetime signalBar);
   void              DrawRange(void);
  };

//+------------------------------------------------------------------+
CAsset::CAsset(void)
  {
   Configure(false, "", 0, 0.0, 1.0);
  }

//+------------------------------------------------------------------+
void CAsset::Configure(const bool en, const string sym, const int startHour,
                       const double maxSpread, const double pip)
  {
   symbol = sym;
   StringTrimLeft(symbol);
   StringTrimRight(symbol);
   enabled         = (en && StringLen(symbol) > 0);
   rangeStartHour  = startHour;
   maxSpreadPips   = maxSpread;
   pipSize         = pip;

   lastBarOpen      = 0;
   lastProcessedBar = 0;
   pendingDir       = 0;
   pendingHeight    = 0.0;
   pendingBarTime   = 0;
   pendingExpiry    = 0;
   pendingNextAttempt = 0;
   pendingWait      = "";
   lastLog          = "";
   StartSession(0);
  }

//+------------------------------------------------------------------+
void CAsset::AssetLog(const string msg)
  {
   LogMsg(symbol + ": " + msg);
  }

//--- log a message only if it differs from the previous one
void CAsset::LogOnce(const string msg)
  {
   if(msg == lastLog)
      return;
   lastLog = msg;
   AssetLog(msg);
  }

//--- start of the session (= range start, Israel time) that contains 'il'
datetime CAsset::SessionStartFor(const datetime il)
  {
   MqlDateTime s;
   TimeToStruct(il, s);
   s.hour = rangeStartHour;
   s.min  = 0;
   s.sec  = 0;
   datetime start = StructToTime(s);
   if(start > il)
      start -= 86400;
   return start;
  }

//--- new session: forget the old range and all breakout flags
void CAsset::StartSession(const datetime sessIL)
  {
   sessionStartIL = sessIL;
   rangeReady     = false;
   rangeFailed    = false;
   rangeHigh      = 0.0;
   rangeLow       = 0.0;
   rangeBars      = 0;
   rangeStartSrv  = 0;
   rangeEndSrv    = 0;
   brokeAbove     = false;
   brokeBelow     = false;
   lastAboveBar   = 0;
   lastBelowBar   = 0;
  }

//+------------------------------------------------------------------+
//| Called on every tick / timer event.                              |
//| IsNewBar guard: bar logic runs ONCE per new M5 bar of the symbol.|
//+------------------------------------------------------------------+
void CAsset::Update(const bool entriesBlocked, const string blockReason)
  {
   if(!enabled)
      return;

   datetime t0 = iTime(symbol, PERIOD_M5, 0);
   if(t0 > 0 && t0 != lastBarOpen)
     {
      //--- a pending entry belongs to the bar that just ended
      if(pendingDir != 0)
         SkipPending("bar N+1 ended before the order could be placed");
      //--- first run = replay history without trading (rebuilds range + flags)
      if(ProcessNewBars(lastProcessedBar != 0))
         lastBarOpen = t0;
     }

   if(pendingDir != 0)
      TryPendingEntry(entriesBlocked, blockReason);
  }

//+------------------------------------------------------------------+
//| Evaluate every closed M5 bar not seen yet. Only the newest one   |
//| (bar N, just closed) may trade; older ones only update state.    |
//+------------------------------------------------------------------+
bool CAsset::ProcessNewBars(const bool liveMode)
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, false);                 // index 0 = oldest
   int n = CopyRates(symbol, PERIOD_M5, 1, HISTORY_BARS, rates);
   if(n <= 0)
     {
      LogOnce("waiting for M5 history (error " + IntegerToString(GetLastError()) + ")");
      return false;
     }
   if(n < HISTORY_BARS && SeriesInfoInteger(symbol, PERIOD_M5, SERIES_SYNCHRONIZED) == 0)
     {
      LogOnce("M5 history is still synchronizing...");
      return false;
     }

   for(int k = 0; k < n; k++)
     {
      if(rates[k].time <= lastProcessedBar)
         continue;
      ProcessClosedBar(rates, k, liveMode && k == n - 1);
      lastProcessedBar = rates[k].time;
     }
   return true;
  }

//+------------------------------------------------------------------+
void CAsset::ProcessClosedBar(const MqlRates &rates[], const int k, const bool canTrade)
  {
   datetime barIL = ServerToIsrael(rates[k].time);
   datetime sess  = SessionStartFor(barIL);
   if(sess != sessionStartIL)
      StartSession(sess);

   long elapsed = (long)(barIL - sessionStartIL);
   if(elapsed < g_rangeSec)
      return;                                      // range measurement phase - no trading
   if(elapsed >= g_rangeSec + g_tradeSec)
      return;                                      // after the active window

   if(!rangeReady)
     {
      if(rangeFailed)
         return;
      BuildRange(rates, k);
      if(!rangeReady)
         return;
     }
   EvaluateBar(rates[k], canTrade);
  }

//+------------------------------------------------------------------+
//| Static High/Low of all M5 bars inside [start, start + 4h) IL.    |
//+------------------------------------------------------------------+
void CAsset::BuildRange(const MqlRates &rates[], const int k)
  {
   datetime winEnd = sessionStartIL + g_rangeSec;
   int      digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

//--- the copied history must start before the range window
   if(ServerToIsrael(rates[0].time) >= sessionStartIL)
     {
      rangeFailed = true;
      AssetLog("not enough history to measure the range of " +
               TimeToString(sessionStartIL, TIME_DATE | TIME_MINUTES) + " IL - no trading this session");
      return;
     }

   double   hi       = -DBL_MAX;
   double   lo       = DBL_MAX;
   int      count    = 0;
   datetime lastSrv  = 0;
   for(int j = 0; j < k; j++)
     {
      datetime il = ServerToIsrael(rates[j].time);
      if(il < sessionStartIL || il >= winEnd)
         continue;
      if(rates[j].high > hi)
         hi = rates[j].high;
      if(rates[j].low < lo)
         lo = rates[j].low;
      lastSrv = rates[j].time;
      count++;
     }

   if(count < InpMinRangeBars || hi <= lo)
     {
      rangeFailed = true;
      AssetLog(StringFormat("range %s IL has only %d M5 bars (min %d) - no trading this session",
                            TimeToString(sessionStartIL, TIME_DATE | TIME_MINUTES), count, InpMinRangeBars));
      return;
     }

   rangeHigh  = hi;
   rangeLow   = lo;
   rangeBars  = count;
   rangeReady = true;

//--- window edges in server time (for drawing)
   long offset   = (long)(ServerToIsrael(lastSrv) - lastSrv);
   rangeStartSrv = (datetime)((long)sessionStartIL - offset);
   rangeEndSrv   = (datetime)((long)winEnd - offset);

   AssetLog(StringFormat("range %s-%s IL  High %s  Low %s  (%d bars)",
                         TimeToString(sessionStartIL, TIME_DATE | TIME_MINUTES),
                         TimeToString(winEnd, TIME_MINUTES),
                         DoubleToString(rangeHigh, digits), DoubleToString(rangeLow, digits), count));
   DrawRange();
  }

//+------------------------------------------------------------------+
//| Core entry logic on closed bar N.                                |
//+------------------------------------------------------------------+
void CAsset::EvaluateBar(const MqlRates &bar, const bool canTrade)
  {
   double c = bar.close;

//--- 1) signal: breakout happened on bar N-1 or earlier, bar N closes back
   bool sellSig = (brokeAbove && c <= rangeHigh);
   bool buySig  = (brokeBelow && c >= rangeLow);
   int  dir     = 0;
   if(sellSig && buySig)
      dir = (lastAboveBar >= lastBelowBar) ? -1 : 1;  // follow the most recent breakout
   else
      if(sellSig)
         dir = -1;
      else
         if(buySig)
            dir = 1;

//--- 2) register a breakout on this bar (it only counts for LATER bars)
   if(c > rangeHigh)
     {
      brokeAbove   = true;
      lastAboveBar = bar.time;
     }
   if(c < rangeLow)
     {
      brokeBelow   = true;
      lastBelowBar = bar.time;
     }

   if(dir == 0)
      return;

//--- history replay: assume the signal was used, needs a fresh breakout
   if(!canTrade)
     {
      ConsumeBreakouts(bar.time);
      return;
     }
   CreatePending(dir, bar);
  }

//+------------------------------------------------------------------+
void CAsset::CreatePending(const int dir, const MqlRates &bar)
  {
   string side   = (dir > 0) ? "BUY" : "SELL";
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double height = bar.high - bar.low;
   if(height <= 0.0)
     {
      AssetLog(side + " signal ignored: signal candle has zero height");
      ApplySkipPolicy(bar.time);
      return;
     }

   datetime now       = TimeTradeServer();
   pendingDir         = dir;
   pendingHeight      = height;
   pendingBarTime     = bar.time;
   pendingExpiry      = now + InpEntryRetrySeconds;
   pendingNextAttempt = 0;
   pendingWait        = "";

   AssetLog(StringFormat("%s signal: bar %s closed %s back inside range [%s - %s], candle height %s",
                         side, TimeToString(bar.time, TIME_DATE | TIME_MINUTES),
                         DoubleToString(bar.close, digits), DoubleToString(rangeLow, digits),
                         DoubleToString(rangeHigh, digits), DoubleToString(height, digits)));

//--- the order must go out at the OPEN of bar N+1, not minutes later
   datetime t0 = iTime(symbol, PERIOD_M5, 0);
   if(t0 > 0 && (long)(now - t0) >= PeriodSeconds(PERIOD_M5) - 10)
      SkipPending("signal detected too late inside bar N+1 (terminal was offline or lagging)");
  }

//+------------------------------------------------------------------+
//| Try to execute the pending signal (retries for a few seconds on  |
//| wide spread / requotes / connection hiccups).                    |
//+------------------------------------------------------------------+
void CAsset::TryPendingEntry(const bool entriesBlocked, const string blockReason)
  {
   datetime now = TimeTradeServer();
   if(entriesBlocked)
     {
      SkipPending(blockReason);
      return;
     }
   if(now > pendingExpiry)
     {
      SkipPending("entry window expired" + (pendingWait != "" ? " (last blocker: " + pendingWait + ")" : ""));
      return;
     }
   if(now < pendingNextAttempt)
      return;

//--- global constraint: maximum 1 open position on the account
   string why = "";
   if(!EntryGateOpen(why))
     {
      SetWait(why, "");
      return;
     }

   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
     {
      SetWait("no valid quote", "");
      return;
     }

//--- spread filter
   double spreadPips = (tick.ask - tick.bid) / pipSize;
   if(maxSpreadPips > 0.0 && spreadPips > maxSpreadPips)
     {
      SetWait("spread above maximum", StringFormat("%.2f > %.2f pips", spreadPips, maxSpreadPips));
      return;
     }

   bool isBuy = (pendingDir > 0);
   ENUM_SYMBOL_TRADE_MODE mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY ||
      (isBuy && mode == SYMBOL_TRADE_MODE_SHORTONLY) || (!isBuy && mode == SYMBOL_TRADE_MODE_LONGONLY))
     {
      SkipPending("symbol trade mode does not allow this direction");
      return;
     }

//--- SL = 1.5 x candle height, TP = 2 x SL distance, measured from the entry price
   double entry  = isBuy ? tick.ask : tick.bid;
   double slDist = pendingHeight * InpSLMultiplier;
   double tpDist = slDist * InpRewardRisk;
   double sl     = RoundToTick(symbol, isBuy ? entry - slDist : entry + slDist);
   double tp     = RoundToTick(symbol, isBuy ? entry + tpDist : entry - tpDist);

//--- broker minimum stop distance
   double point   = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double minDist = (double)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   bool   stopsOk = isBuy ? (sl > 0.0 && sl < tick.bid - minDist && tp > tick.bid + minDist)
                          : (tp > 0.0 && sl > tick.ask + minDist && tp < tick.ask - minDist);
   if(!stopsOk)
     {
      SkipPending("SL/TP too close to price (signal candle too small vs spread/stop level)");
      return;
     }

//--- position size from Risk_Percent_Per_Trade
   double lots   = 0.0;
   string lotWhy = "";
   if(!CalculateLots(symbol, isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, entry, sl, lots, lotWhy))
     {
      SkipPending(lotWhy);
      return;
     }

//--- send
   pendingNextAttempt = now + 2;                   // at most one order request every 2s
   g_trade.SetTypeFillingBySymbol(symbol);
   string cmt  = InpComment + (isBuy ? " BUY" : " SELL");
   bool   sent = isBuy ? g_trade.Buy(lots, symbol, entry, sl, tp, cmt)
                       : g_trade.Sell(lots, symbol, entry, sl, tp, cmt);
   uint   rc   = g_trade.ResultRetcode();

   if(sent && IsSuccessRetcode(rc))
     {
      g_entryPlacedThisPass = true;
      g_lastEntryTime       = now;
      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

      //--- re-anchor SL/TP to the real fill price if there was slippage
      double fill     = g_trade.ResultPrice();
      double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      if(fill > 0.0 && tickSize > 0.0 && MathAbs(fill - entry) >= tickSize)
        {
         ulong  posTicket = g_trade.ResultOrder();  // position ticket = opening order ticket
         double nsl       = RoundToTick(symbol, isBuy ? fill - slDist : fill + slDist);
         double ntp       = RoundToTick(symbol, isBuy ? fill + tpDist : fill - tpDist);
         if(posTicket > 0 && PositionSelectByTicket(posTicket) && g_trade.PositionModify(posTicket, nsl, ntp))
           {
            sl = nsl;
            tp = ntp;
           }
        }
      if(fill <= 0.0)
         fill = entry;

      Notify(StringFormat("%s %s %.2f lots @ %s | SL %s | TP %s | risk %.2f%%",
                          (isBuy ? "BUY" : "SELL"), symbol, lots, DoubleToString(fill, digits),
                          DoubleToString(sl, digits), DoubleToString(tp, digits), InpRiskPercent));

      //--- Flag reset: a fresh close outside the range is required for the next trade
      ConsumeBreakouts(pendingBarTime);
      pendingDir  = 0;
      pendingWait = "";
      return;
     }

   string err = StringFormat("%u %s", rc, g_trade.ResultRetcodeDescription());
   if(IsPermanentRetcode(rc))
      SkipPending("order rejected: " + err);
   else
      SetWait("order rejected, retrying", err);
  }

//--- remember why the entry is on hold (logged once per reason)
void CAsset::SetWait(const string key, const string detail)
  {
   if(key == pendingWait)
      return;
   pendingWait = key;
   AssetLog("entry on hold: " + key + (detail != "" ? " (" + detail + ")" : ""));
  }

void CAsset::SkipPending(const string reason)
  {
   if(pendingDir == 0)
      return;
   AssetLog(StringFormat("%s signal of bar %s NOT traded: %s",
                         (pendingDir > 0 ? "BUY" : "SELL"),
                         TimeToString(pendingBarTime, TIME_DATE | TIME_MINUTES), reason));
   ApplySkipPolicy(pendingBarTime);
   pendingDir  = 0;
   pendingWait = "";
  }

void CAsset::ApplySkipPolicy(const datetime signalBar)
  {
   if(!InpKeepBreakoutOnSkip)
      ConsumeBreakouts(signalBar);
  }

//--- clear breakouts that happened BEFORE the signal bar
//--- (a close outside the range on the signal bar itself is a fresh breakout and is kept)
void CAsset::ConsumeBreakouts(const datetime signalBar)
  {
   if(brokeAbove && lastAboveBar < signalBar)
      brokeAbove = false;
   if(brokeBelow && lastBelowBar < signalBar)
      brokeBelow = false;
  }

//+------------------------------------------------------------------+
void CAsset::DrawRange(void)
  {
   if(!InpDrawRanges || g_isOptimization || (g_isTester && !g_isVisual))
      return;
   if(symbol != _Symbol)
      return;

   string   base        = OBJ_PREFIX + symbol + "_" + IntegerToString((long)sessionStartIL);
   string   rect        = base + "_range";
   datetime tradeEndSrv = rangeEndSrv + g_tradeSec;

   ObjectDelete(0, rect);
   if(ObjectCreate(0, rect, OBJ_RECTANGLE, 0, rangeStartSrv, rangeHigh, rangeEndSrv, rangeLow))
     {
      ObjectSetInteger(0, rect, OBJPROP_COLOR, clrSteelBlue);
      ObjectSetInteger(0, rect, OBJPROP_FILL, false);
      ObjectSetInteger(0, rect, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, rect, OBJPROP_BACK, true);
      ObjectSetInteger(0, rect, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, rect, OBJPROP_HIDDEN, true);
     }
   DrawLevel(base + "_high", rangeEndSrv, tradeEndSrv, rangeHigh, clrTomato);
   DrawLevel(base + "_low", rangeEndSrv, tradeEndSrv, rangeLow, clrMediumSeaGreen);
  }

//+------------------------------------------------------------------+
string CAsset::StatusLine(const datetime nowIL)
  {
   if(!enabled)
      return StringFormat("%-11s disabled", symbol);

   datetime s     = SessionStartFor(nowIL);
   long     el    = (long)(nowIL - s);
   bool     cur   = (sessionStartIL == s);
   string   phase = "";
   if(el < g_rangeSec)
      phase = "MEASURING RANGE until " + TimeToString(s + g_rangeSec, TIME_MINUTES) + " IL";
   else
      if(el >= g_rangeSec + g_tradeSec)
         phase = "IDLE (active window over)";
      else
         if(cur && rangeFailed)
            phase = "NO VALID RANGE this session";
         else
            if(cur && rangeReady)
               phase = "ACTIVE until " + TimeToString(s + g_rangeSec + g_tradeSec, TIME_MINUTES) + " IL";
            else
               phase = "WAITING FOR FIRST BAR";

   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   string rng    = "H -  L -";
   if(cur && rangeReady)
      rng = "H " + DoubleToString(rangeHigh, digits) + "  L " + DoubleToString(rangeLow, digits);

   double  spread = 0.0;
   MqlTick t;
   if(SymbolInfoTick(symbol, t) && pipSize > 0.0)
      spread = (t.ask - t.bid) / pipSize;

   string pend = "";
   if(pendingDir != 0)
      pend = (pendingDir > 0) ? "  | PENDING BUY" : "  | PENDING SELL";

   return StringFormat("%-11s %s | %s | breakout up:%s dn:%s | spread %.2f/%.2f pips%s",
                       symbol, phase, rng, (brokeAbove ? "Y" : "n"), (brokeBelow ? "Y" : "n"),
                       spread, maxSpreadPips, pend);
  }

//+------------------------------------------------------------------+
//| Asset instances                                                  |
//+------------------------------------------------------------------+
CAsset g_assets[ASSET_COUNT];

//+------------------------------------------------------------------+
//| Daily loss kill-switch                                           |
//+------------------------------------------------------------------+
long DayKey(const datetime serverTime)
  {
   return ((long)serverTime - (long)InpDailyResetHour * 3600) / 86400;
  }

string GVName(const string key)
  {
   return "RBR_" + IntegerToString((long)InpMagic) + "_" +
          IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + key;
  }

//--- persist the day reference so a restart does not reset the kill-switch
void SaveDailyState()
  {
   if(g_isTester || g_dayKey < 0)
      return;
   GlobalVariableSet(GVName("day"), (double)g_dayKey);
   GlobalVariableSet(GVName("ref"), g_dayStartRef);
   GlobalVariableSet(GVName("halt"), g_dailyHalt ? 1.0 : 0.0);
   GlobalVariablesFlush();
  }

void LoadDailyState()
  {
   g_dayKey      = -1;
   g_dayStartRef = 0.0;
   g_dailyHalt   = false;
   if(g_isTester)
      return;

   string nDay = GVName("day");
   string nRef = GVName("ref");
   string nHlt = GVName("halt");
   if(!GlobalVariableCheck(nDay) || !GlobalVariableCheck(nRef))
      return;
   long storedDay = (long)GlobalVariableGet(nDay);
   if(storedDay != DayKey(TimeTradeServer()))
      return;

   g_dayKey      = storedDay;
   g_dayStartRef = GlobalVariableGet(nRef);
   g_dailyHalt   = (GlobalVariableCheck(nHlt) && GlobalVariableGet(nHlt) > 0.5);
   LogMsg(StringFormat("Restored today's state: reference equity %.2f%s",
                       g_dayStartRef, g_dailyHalt ? " - KILL-SWITCH ACTIVE" : ""));
  }

double DailyLossLimitAmount()
  {
   double base = (InpDailyLossBase > 0.0) ? InpDailyLossBase : g_dayStartRef;
   return base * InpDailyLossPercent / 100.0;
  }

void UpdateDailyLossGuard(const datetime nowSrv)
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance <= 0.0)
      return;                                      // account data not ready yet

   long key = DayKey(nowSrv);
   if(key != g_dayKey)
     {
      bool wasHalted = g_dailyHalt;
      g_dayKey      = key;
      g_dayStartRef = MathMax(balance, equity);    // conservative reference
      g_dailyHalt   = false;
      SaveDailyState();
      LogMsg(StringFormat("New trading day: reference equity %.2f, daily loss limit %.2f",
                          g_dayStartRef, DailyLossLimitAmount()));
      if(wasHalted)
         Notify("New trading day - daily loss kill-switch released.");
     }

   if(InpDailyLossPercent <= 0.0)
      return;

//--- equity-based: covers realized AND floating loss
   double loss  = g_dayStartRef - equity;
   double limit = DailyLossLimitAmount();
   if(!g_dailyHalt && loss >= limit)
     {
      g_dailyHalt        = true;
      g_nextCloseAttempt = 0;
      SaveDailyState();
      Notify(StringFormat("DAILY LOSS KILL-SWITCH: loss %.2f >= limit %.2f. Closing positions, no trading until the next day.",
                          loss, limit));
     }
   if(g_dailyHalt && HasGuardedPositions())
      CloseGuardedPositions("Daily loss kill-switch");
  }

//+------------------------------------------------------------------+
//| Friday close-out (FTMO: no weekend holding)                      |
//+------------------------------------------------------------------+
void HandleFridayCloseOut(const datetime nowIL)
  {
   if(!IsWeekendBlock(nowIL))
      return;

   long dayIdx = (long)nowIL / 86400;
   if(dayIdx != g_fridayNoticeDay && IsAfterFridayCutoff(nowIL))
     {
      g_fridayNoticeDay = dayIdx;
      LogMsg(StringFormat("Friday %02d:%02d Israel time reached: closing positions, no new entries until Monday.",
                          InpFridayCloseHour, InpFridayCloseMinute));
     }
   if(HasGuardedPositions())
      CloseGuardedPositions("Friday close-out");
  }

//+------------------------------------------------------------------+
//| Chart panel                                                      |
//+------------------------------------------------------------------+
void UpdatePanel(const datetime nowSrv, const datetime nowIL)
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   string limitTxt = (InpDailyLossPercent > 0.0) ? StringFormat("-%.2f", DailyLossLimitAmount()) : "off";

   string txt = "RANGE RE-ENTRY EA   magic " + IntegerToString((long)InpMagic) + "\n";
   txt += "Server " + TimeToString(nowSrv, TIME_DATE | TIME_MINUTES) +
          "   |   Israel " + TimeToString(nowIL, TIME_DATE | TIME_MINUTES) + "\n";
   txt += StringFormat("Day P/L %.2f   |   daily limit %s   |   %s\n",
                       equity - g_dayStartRef, limitTxt, g_dailyHalt ? "KILL-SWITCH ACTIVE" : "OK");
   txt += StringFormat("Open positions %d (max 1)   |   %s\n", PositionsTotal(),
                       IsWeekendBlock(nowIL) ? "WEEKEND BLOCK" : "entries allowed");
   txt += "------------------------------------------------------------------\n";
   for(int i = 0; i < ASSET_COUNT; i++)
      txt += g_assets[i].StatusLine(nowIL) + "\n";
   Comment(txt);
  }

//+------------------------------------------------------------------+
//| Main loop (OnTick of the chart symbol + 1s timer for the others) |
//+------------------------------------------------------------------+
void Run()
  {
   if(!g_ready)
      return;

   g_entryPlacedThisPass = false;
   datetime nowSrv = TimeTradeServer();
   datetime nowIL  = ServerToIsrael(nowSrv);

//--- protection first
   UpdateDailyLossGuard(nowSrv);
   HandleFridayCloseOut(nowIL);

   string blockReason = "";
   if(g_dailyHalt)
      blockReason = "daily loss kill-switch active";
   else
      if(IsWeekendBlock(nowIL))
         blockReason = "Friday close-out / weekend";

   for(int i = 0; i < ASSET_COUNT; i++)
      g_assets[i].Update(blockReason != "", blockReason);

   if(InpShowPanel && nowSrv != g_lastPanelUpdate && (!g_isTester || g_isVisual))
     {
      g_lastPanelUpdate = nowSrv;
      UpdatePanel(nowSrv, nowIL);
     }
  }

//+------------------------------------------------------------------+
//| Compare the EA's Israel clock with the PC clock (live only)      |
//+------------------------------------------------------------------+
void PrintTimeDiagnostics()
  {
   datetime srv = TimeTradeServer();
   datetime il  = ServerToIsrael(srv);
   LogMsg("Time check: server " + TimeToString(srv, TIME_DATE | TIME_MINUTES) +
          " -> Israel " + TimeToString(il, TIME_DATE | TIME_MINUTES) +
          (InpTimeMode == TIME_MODE_AUTO ? " (auto mode)" : " (manual mode)"));
   if(g_isTester)
      return;

   datetime ilFromPc = UTCToIsrael(TimeGMT());
   long     diff     = (long)(il - ilFromPc);
   if(diff < 0)
      diff = -diff;
   if(diff > 15 * 60)
     {
      long realOffsetMin = (long)MathRound((double)(srv - TimeGMT()) / 900.0) * 15;
      string msg = StringFormat("TIME ALIGNMENT WARNING: EA Israel time %s but PC clock says %s. "
                                "Broker server is GMT%+.2f right now - fix the Time Alignment inputs!",
                                TimeToString(il, TIME_MINUTES), TimeToString(ilFromPc, TIME_MINUTES),
                                realOffsetMin / 60.0);
      LogMsg(msg);
      Alert(msg);
     }
   else
      LogMsg("Time alignment OK (matches PC clock).");
  }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_ready          = false;
   g_isTester       = (MQLInfoInteger(MQL_TESTER) != 0);
   g_isOptimization = (MQLInfoInteger(MQL_OPTIMIZATION) != 0);
   g_isVisual       = (MQLInfoInteger(MQL_VISUAL_MODE) != 0);

//--- input validation
   string err = "";
   if(InpRangeHours < 1 || InpTradeHours < 1 || InpRangeHours + InpTradeHours > 24)
      err = "range hours + trade hours must be between 2 and 24";
   else
      if(InpSLMultiplier <= 0.0 || InpRewardRisk <= 0.0)
         err = "SL multiplier and reward:risk must be > 0";
      else
         if(InpRiskPercent <= 0.0 || InpRiskPercent > 10.0)
            err = "Risk_Percent_Per_Trade must be in (0, 10]";
         else
            if(InpDailyLossPercent < 0.0 || InpDailyLossPercent > 50.0)
               err = "Daily_Loss_Limit_Percent must be in [0, 50]";
            else
               if(InpDailyResetHour < 0 || InpDailyResetHour > 23)
                  err = "daily reset hour must be 0-23";
               else
                  if(InpFridayCloseHour < 0 || InpFridayCloseHour > 23 || InpFridayCloseMinute < 0 || InpFridayCloseMinute > 59)
                     err = "Friday close-out time is invalid";
                  else
                     if(InpEntryRetrySeconds < 0 || InpEntryRetrySeconds > 240)
                        err = "entry retry seconds must be 0-240";
                     else
                        if(InpMinRangeBars < 1)
                           err = "min range bars must be >= 1";
                        else
                           if(InpServerGMTOffset < -12 || InpServerGMTOffset > 14 ||
                              InpManualIsraelOffset < -24 || InpManualIsraelOffset > 24)
                              err = "time offsets are out of range";

   int    starts[ASSET_COUNT] = {0, 0, 0, 0};
   double pips[ASSET_COUNT]   = {0, 0, 0, 0};
   starts[0] = InpA1_RangeStart; starts[1] = InpA2_RangeStart; starts[2] = InpA3_RangeStart; starts[3] = InpA4_RangeStart;
   pips[0]   = InpA1_PipSize;    pips[1]   = InpA2_PipSize;    pips[2]   = InpA3_PipSize;    pips[3]   = InpA4_PipSize;
   for(int i = 0; i < ASSET_COUNT && err == ""; i++)
     {
      if(starts[i] < 0 || starts[i] > 23)
         err = StringFormat("asset %d: range start hour must be 0-23", i + 1);
      else
         if(pips[i] <= 0.0)
            err = StringFormat("asset %d: pip size must be > 0", i + 1);
     }
   if(err != "")
     {
      LogMsg("INVALID INPUT: " + err);
      return INIT_PARAMETERS_INCORRECT;
     }

   g_rangeSec = InpRangeHours * 3600;
   g_tradeSec = InpTradeHours * 3600;
   g_dstYear  = -1;

//--- assets
   g_assets[0].Configure(InpA1_Enabled, InpA1_Symbol, InpA1_RangeStart, InpA1_MaxSpread, InpA1_PipSize);
   g_assets[1].Configure(InpA2_Enabled, InpA2_Symbol, InpA2_RangeStart, InpA2_MaxSpread, InpA2_PipSize);
   g_assets[2].Configure(InpA3_Enabled, InpA3_Symbol, InpA3_RangeStart, InpA3_MaxSpread, InpA3_PipSize);
   g_assets[3].Configure(InpA4_Enabled, InpA4_Symbol, InpA4_RangeStart, InpA4_MaxSpread, InpA4_PipSize);

   int active = 0;
   for(int i = 0; i < ASSET_COUNT; i++)
     {
      if(!g_assets[i].enabled)
         continue;
      if(!SymbolSelect(g_assets[i].symbol, true))
        {
         LogMsg("Symbol '" + g_assets[i].symbol + "' not found at this broker - asset disabled. "
                "Check the exact name in Market Watch (e.g. US100.cash / NAS100 / USTEC).");
         g_assets[i].enabled = false;
         continue;
        }
      active++;
      LogMsg(StringFormat("Asset %s: range %02d:00-%02d:00 IL, active %d h, max spread %.2f pips (pip = %s)",
                          g_assets[i].symbol, g_assets[i].rangeStartHour,
                          (g_assets[i].rangeStartHour + InpRangeHours) % 24, InpTradeHours,
                          g_assets[i].maxSpreadPips, DoubleToString(g_assets[i].pipSize, 5)));
     }
   if(active == 0)
     {
      LogMsg("No valid symbol enabled - EA stopped.");
      return INIT_FAILED;
     }

//--- trade object
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints((ulong)InpSlippagePoints);
   g_trade.SetMarginMode();
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

//--- state
   g_entryPlacedThisPass = false;
   g_lastEntryTime       = 0;
   g_nextCloseAttempt    = 0;
   g_lastCloseError      = "";
   g_lastCloseErrorLog   = 0;
   g_fridayNoticeDay     = -1;
   g_lastPanelUpdate     = 0;
   LoadDailyState();
   PrintTimeDiagnostics();

   EventSetTimer(1);
   g_ready = true;
   LogMsg(StringFormat("Started: %d asset(s), risk %.2f%%/trade, daily loss limit %.2f%%, max 1 position.",
                       active, InpRiskPercent, InpDailyLossPercent));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   SaveDailyState();
   g_ready = false;
   if(!g_isTester)
     {
      Comment("");
      ObjectsDeleteAll(0, OBJ_PREFIX);
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   Run();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   Run();
  }

//+------------------------------------------------------------------+
//| Push a message to the phone when one of our positions closes     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;

   long entryType = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entryType != DEAL_ENTRY_OUT && entryType != DEAL_ENTRY_OUT_BY)
      return;

   string sym    = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   long   reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
   long   posId  = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   double pnl    = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) +
                   HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                   HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   bool   ours   = (HistoryDealGetInteger(trans.deal, DEAL_MAGIC) == (long)InpMagic);

//--- SL/TP deals may not carry the magic: check the opening deal of the position
   if(!ours && posId > 0 && HistorySelectByPosition(posId))
     {
      for(int i = 0; i < HistoryDealsTotal(); i++)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d > 0 && HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
           {
            ours = (HistoryDealGetInteger(d, DEAL_MAGIC) == (long)InpMagic);
            break;
           }
        }
     }
   if(!ours)
      return;

   string why = "closed";
   if(reason == DEAL_REASON_TP)
      why = "TAKE PROFIT";
   else
      if(reason == DEAL_REASON_SL)
         why = "STOP LOSS";
      else
         if(reason == DEAL_REASON_SO)
            why = "STOP OUT";
         else
            if(reason == DEAL_REASON_EXPERT)
               why = "closed by EA";
   Notify(StringFormat("%s %s | P/L %.2f %s", sym, why, pnl, AccountInfoString(ACCOUNT_CURRENCY)));
  }
//+------------------------------------------------------------------+
