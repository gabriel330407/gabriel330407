//+------------------------------------------------------------------+
//| ExportBars.mq5 - export M1 history to CSV, one file per symbol/year
//| Output: <MT5 data folder>\MQL5\Files\export\SYMBOL_YEAR.csv
//| Times are broker SERVER time (FTMO: GMT+2 / GMT+3 "New York close").
//| Before running: Tools > Options > Charts > Max bars in chart = Unlimited
//+------------------------------------------------------------------+
#property script_show_inputs
#property version "1.00"

input string          InpSymbols = "XAUUSD,US100.cash,US500.cash,EURUSD,GBPJPY,EURJPY,GER40.cash";
input ENUM_TIMEFRAMES InpTF      = PERIOD_M1;
input int             InpFromYear = 2015;

void OnStart()
  {
   string syms[];
   int n = StringSplit(InpSymbols, ',', syms);
   for(int i = 0; i < n; i++)
     {
      string sym = syms[i];
      StringTrimLeft(sym);
      StringTrimRight(sym);
      if(sym == "")
         continue;
      if(!SymbolSelect(sym, true))
        {
         PrintFormat("%s: symbol not found", sym);
         continue;
        }
      ExportSymbol(sym);
     }
   Print("Export finished. Folder: ", TerminalInfoString(TERMINAL_DATA_PATH), "\\MQL5\\Files\\export");
  }

void ExportSymbol(const string sym)
  {
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   string clean = sym;
   StringReplace(clean, ".", "_");
   for(int y = InpFromYear; y <= now.year; y++)
     {
      datetime from = StringToTime(IntegerToString(y) + ".01.01 00:00");
      datetime to   = StringToTime(IntegerToString(y + 1) + ".01.01 00:00") - 1;
      MqlRates rates[];
      int got = -1;
      for(int tries = 0; tries < 30 && got <= 0; tries++)
        {
         got = CopyRates(sym, InpTF, from, to, rates);   // triggers history download
         if(got <= 0)
            Sleep(1000);
        }
      if(got <= 0)
        {
         PrintFormat("%s %d: no data (error %d)", sym, y, GetLastError());
         continue;
        }
      string fname = StringFormat("export\\%s_%d.csv", clean, y);
      int h = FileOpen(fname, FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(h == INVALID_HANDLE)
        {
         PrintFormat("cannot open %s (error %d)", fname, GetLastError());
         continue;
        }
      FileWriteString(h, "datetime,open,high,low,close,tickvol,spread\r\n");
      for(int k = 0; k < got; k++)
         FileWriteString(h, TimeToString(rates[k].time, TIME_DATE | TIME_SECONDS) + "," +
                         DoubleToString(rates[k].open, digits) + "," +
                         DoubleToString(rates[k].high, digits) + "," +
                         DoubleToString(rates[k].low, digits) + "," +
                         DoubleToString(rates[k].close, digits) + "," +
                         IntegerToString(rates[k].tick_volume) + "," +
                         IntegerToString(rates[k].spread) + "\r\n");
      FileClose(h);
      PrintFormat("%s %d: %d bars -> %s", sym, y, got, fname);
     }
  }
