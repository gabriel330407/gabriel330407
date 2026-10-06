"""Research configuration: instruments, trading window, cost model.

All times the trader cares about are Israel local time (Asia/Jerusalem),
including DST. Price data is converted to UTC on load and then to Israel time,
so the 19:00-21:00 window is always the trader's wall-clock window.
"""

TZ_LOCAL = "Asia/Jerusalem"
TZ_NY = "America/New_York"

# Trading window (Israel local time), minutes from midnight
WIN_START = 19 * 60          # 19:00
WIN_END = 21 * 60            # 21:00 (all trades flat by then)
LAST_ENTRY = 20 * 60 + 30    # no new entries after 20:30 (needs room to reach 2R)
WIN_LEN = WIN_END - WIN_START

# Context session start for "day" features (Israel local) ~ CME/FX reopen
DAY_START = 1 * 60           # 01:00

# In-sample / out-of-sample split
OOS_START = "2022-01-01"

# cost: round-trip cost per trade in PRICE units (spread + commission), FTMO-like,
#       deliberately on the conservative side for the 19:00-21:00 Israel window.
# slip: extra slippage in PRICE units charged on every stop-order fill
#       (stop-loss exits and breakout entries); limit orders get none.
INSTRUMENTS = {
    # key: (dukascopy symbol, price divisor, round-trip cost, FTMO symbol)
    "XAUUSD": dict(duka="XAUUSD", div=1e3, cost=0.35, slip=0.10, ftmo="XAUUSD"),
    "US100": dict(duka="USATECHIDXUSD", div=1e3, cost=1.5, slip=0.5, ftmo="US100.cash"),
    "US500": dict(duka="USA500IDXUSD", div=1e3, cost=0.6, slip=0.15, ftmo="US500.cash"),
    "EURUSD": dict(duka="EURUSD", div=1e5, cost=0.00008, slip=0.00002, ftmo="EURUSD"),
    "GBPJPY": dict(duka="GBPJPY", div=1e3, cost=0.025, slip=0.005, ftmo="GBPJPY"),
    "EURJPY": dict(duka="EURJPY", div=1e3, cost=0.018, slip=0.004, ftmo="EURJPY"),
    "GER40": dict(duka="DEUIDXEUR", div=1e3, cost=2.0, slip=0.5, ftmo="GER40.cash"),
    # synthetic test series (make_synthetic.py): cost ~4% and slip ~1.2% of WR20,
    # the same proportions as gold in this window
    "SYN": dict(duka=None, div=1, cost=0.08, slip=0.025, ftmo=None),
}
