"""Turn M1 bars into one row per trading day:
  * O/H/L/C matrices of the 19:00-21:00 Israel window (one column per minute)
  * context features known strictly BEFORE 19:00 (no look-ahead)
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd

from config import DAY_START, TZ_LOCAL, TZ_NY, WIN_LEN, WIN_START


@dataclass
class Days:
    dates: pd.DatetimeIndex     # local trading dates
    O: np.ndarray               # (n, WIN_LEN) window minute bars
    H: np.ndarray
    L: np.ndarray
    C: np.ndarray
    f: pd.DataFrame             # per-day context features (index = dates)


def _ny_open_local_minute(dates: pd.DatetimeIndex) -> np.ndarray:
    """09:30 New York expressed in Israel minutes (16:30 most of the year,
    15:30 in the few weeks where US and Israel DST are out of sync)."""
    ny = (dates + pd.Timedelta(hours=9, minutes=30)).tz_localize(TZ_NY)
    loc = ny.tz_convert(TZ_LOCAL)
    return (loc.hour * 60 + loc.minute).to_numpy()


def build_days(df_utc: pd.DataFrame, min_coverage: float = 0.75, res: int = 1) -> Days:
    """res = bar size of the input in minutes (1 for M1, 5 for M5)."""
    loc = df_utc.tz_convert(TZ_LOCAL)
    # resample anything finer than M1 is not expected; coarser data (M5) is
    # placed on its bar-start minute and forward filled.
    ts = loc.index
    date = ts.tz_localize(None).normalize()
    tod = ts.hour * 60 + ts.minute
    frame = pd.DataFrame({"date": date, "tod": tod, "o": loc["open"].to_numpy(),
                          "h": loc["high"].to_numpy(), "l": loc["low"].to_numpy(),
                          "c": loc["close"].to_numpy()})
    frame = frame[frame["date"].dt.dayofweek < 5]

    # ---------- daily (01:00-24:00) ranges for ATR + previous-day levels ----------
    sess = frame[frame["tod"] >= DAY_START]
    daily = sess.groupby("date").agg(d_open=("o", "first"), d_high=("h", "max"),
                                     d_low=("l", "min"), d_close=("c", "last"))

    # ---------- pre-window context (01:00 .. 18:59) ----------
    pre = sess[sess["tod"] < WIN_START]
    ctx = pre.groupby("date").agg(day_open=("o", "first"), day_high=("h", "max"),
                                  day_low=("l", "min"), pre_close=("c", "last"),
                                  pre_last_tod=("tod", "last"))

    dates_all = daily.index
    ny_open_min = pd.Series(_ny_open_local_minute(pd.DatetimeIndex(dates_all)), index=dates_all)
    pre = pre.join(ny_open_min.rename("nyo"), on="date")
    morning = pre[pre["tod"] >= pre["nyo"]]
    mctx = morning.groupby("date").agg(ny_open=("o", "first"), am_high=("h", "max"),
                                       am_low=("l", "min"))

    # ---------- window matrices ----------
    win = frame[(frame["tod"] >= WIN_START) & (frame["tod"] < WIN_START + WIN_LEN)]
    counts = win.groupby("date").size()
    good = counts[counts * res >= min_coverage * WIN_LEN].index
    good = good.intersection(ctx.index).intersection(mctx.index)
    win = win[win["date"].isin(good)]
    dates = pd.DatetimeIndex(sorted(good))
    row = pd.Series(np.arange(len(dates)), index=dates)
    r = row.loc[win["date"]].to_numpy()
    col = (win["tod"] - WIN_START).to_numpy()

    def mat(vals):
        m = np.full((len(dates), WIN_LEN), np.nan)
        m[r, col] = vals
        return m

    O, H, L, C = (mat(win[k].to_numpy()) for k in ("o", "h", "l", "c"))
    # fill missing minutes with flat bars at the previous close
    prev_close = ctx.loc[dates, "pre_close"].to_numpy()
    C = pd.DataFrame(C).ffill(axis=1).to_numpy()
    C = np.where(np.isnan(C), prev_close[:, None], C)
    prev_c = np.concatenate([prev_close[:, None], C[:, :-1]], axis=1)
    miss = np.isnan(O)
    O = np.where(miss, prev_c, O)
    H = np.where(miss, prev_c, H)
    L = np.where(miss, prev_c, L)
    C = np.where(miss, prev_c, C)

    # ---------- features ----------
    f = pd.DataFrame(index=dates)
    f = f.join(ctx).join(mctx)
    f["p0"] = O[:, 0]                               # price at 19:00
    f["weekday"] = dates.dayofweek                 # 0=Mon
    f["year"] = dates.year
    f["nyo_min"] = ny_open_min.loc[dates].to_numpy()
    # last traded price before 18:00 / 18:30 (lookback anchors for 19:00 / 19:30)
    for name, t in (("p_1800", 18 * 60), ("p_1830", 18 * 60 + 30)):
        f[name] = pre[pre["tod"] < t].groupby("date")["c"].last().reindex(dates).to_numpy()

    wrange = pd.Series(H.max(1) - L.min(1), index=dates)
    # causal volatility references (previous days only)
    f["wr20"] = wrange.rolling(20, min_periods=10).median().shift(1)
    d_range = (daily["d_high"] - daily["d_low"])
    tr = pd.concat([d_range, (daily["d_high"] - daily["d_close"].shift()).abs(),
                    (daily["d_low"] - daily["d_close"].shift()).abs()], axis=1).max(axis=1)
    atr14 = tr.rolling(14, min_periods=10).mean().shift(1)
    f["atr14"] = atr14.reindex(dates).to_numpy()
    prev = daily.shift(1)
    f["pd_high"] = prev["d_high"].reindex(dates).to_numpy()
    f["pd_low"] = prev["d_low"].reindex(dates).to_numpy()
    f["pd_close"] = prev["d_close"].reindex(dates).to_numpy()
    f["w_range"] = wrange  # realised (post-hoc, for reporting only)

    ok = f["wr20"].notna() & f["atr14"].notna() & f["pd_high"].notna()
    keep = ok.to_numpy()
    return Days(dates=dates[keep], O=O[keep], H=H[keep], L=L[keep], C=C[keep],
                f=f[keep].copy())
