"""Load OHLC price files into a clean UTC-indexed M1 (or M5) DataFrame.

Supported inputs (auto-detected):
  * MetaTrader 5 export  (<DATE> <TIME> <OPEN> <HIGH> <LOW> <CLOSE> ...), broker server time
  * MetaTrader 4 / generic headerless  "2020.01.02,01:00,o,h,l,c,v"
  * Dukascopy JForex CSV  ("Gmt time,Open,High,Low,Close,Volume"), UTC
  * Any CSV with a datetime column + open/high/low/close columns
  * Parquet files written by fetch_dukascopy.py (UTC)
  * .zip containing one of the above

Source timezone (`source_tz`):
  "utc"      - timestamps are UTC
  "ny_close" - broker "New York close" server time = New York time + 7h
               (GMT+2 winter / GMT+3 summer, switching on US DST dates).
               This is what FTMO and most MT5 brokers use.
  "eet"      - GMT+2/+3 switching on EU DST dates (Europe/Athens)
  any IANA name, e.g. "Asia/Jerusalem"
"""
from __future__ import annotations

import io
import zipfile
from pathlib import Path

import numpy as np
import pandas as pd

from config import TZ_NY


def _read_text(path: Path) -> str:
    if path.suffix.lower() == ".zip":
        with zipfile.ZipFile(path) as z:
            names = [n for n in z.namelist() if not n.endswith("/")]
            if len(names) != 1:
                raise ValueError(f"{path}: zip must contain exactly one file, has {names}")
            raw = z.read(names[0])
    else:
        raw = path.read_bytes()
    # MT5 exports are often UTF-16
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16")
    return raw.decode("utf-8-sig", errors="replace")


def _parse_frame(text: str) -> tuple[pd.DataFrame, str | None]:
    """Return (df with naive 'ts' + o/h/l/c, implied tz or None)."""
    first = text.splitlines()[0]
    sep = "\t" if "\t" in first else (";" if first.count(";") > first.count(",") else ",")

    if "<DATE>" in first.upper():  # MT5 export
        df = pd.read_csv(io.StringIO(text), sep=sep)
        df.columns = [c.strip("<>").upper() for c in df.columns]
        if "TIME" in df.columns:
            ts = pd.to_datetime(df["DATE"].astype(str) + " " + df["TIME"].astype(str),
                                format="mixed")
        else:
            ts = pd.to_datetime(df["DATE"].astype(str), format="mixed")
        out = pd.DataFrame({"ts": ts, "open": df["OPEN"], "high": df["HIGH"],
                            "low": df["LOW"], "close": df["CLOSE"]})
        if "TICKVOL" in df.columns:
            out["vol"] = df["TICKVOL"]
        return out, None

    if "gmt time" in first.lower():  # Dukascopy JForex export
        df = pd.read_csv(io.StringIO(text), sep=sep)
        df.columns = [c.strip().lower() for c in df.columns]
        ts = pd.to_datetime(df["gmt time"], format="%d.%m.%Y %H:%M:%S.%f")
        out = pd.DataFrame({"ts": ts, "open": df["open"], "high": df["high"],
                            "low": df["low"], "close": df["close"]})
        if "volume" in df.columns:
            out["vol"] = df["volume"]
        return out, "utc"

    has_header = any(ch.isalpha() for ch in first)
    if has_header:
        df = pd.read_csv(io.StringIO(text), sep=sep)
        cols = {c.lower().strip(): c for c in df.columns}
        pick = lambda *names: next((cols[n] for n in names if n in cols), None)
        c_dt = pick("datetime", "timestamp", "time", "date_time", "gmt time", "local time")
        c_d, c_t = pick("date", "day"), pick("time", "hour")
        if c_d and c_t and c_d != c_t:
            ts = pd.to_datetime(df[c_d].astype(str) + " " + df[c_t].astype(str), format="mixed")
        elif c_dt:
            ts = pd.to_datetime(df[c_dt], format="mixed", utc=False)
            if getattr(ts.dt, "tz", None) is not None:
                ts = ts.dt.tz_convert("UTC").dt.tz_localize(None)
                return (pd.DataFrame({"ts": ts, "open": df[pick("open", "o")],
                                      "high": df[pick("high", "h")], "low": df[pick("low", "l")],
                                      "close": df[pick("close", "c")]}), "utc")
        else:
            raise ValueError(f"cannot find a time column in header: {list(df.columns)}")
        return pd.DataFrame({"ts": ts, "open": df[pick("open", "o")], "high": df[pick("high", "h")],
                             "low": df[pick("low", "l")], "close": df[pick("close", "c")]}), None

    # headerless: MT4 "2020.01.02,01:00,o,h,l,c,v" or HistData "20200102 010000;o;h;l;c;v"
    df = pd.read_csv(io.StringIO(text), sep=sep, header=None)
    if isinstance(df.iloc[0, 1], str) and ":" in df.iloc[0, 1]:
        ts = pd.to_datetime(df[0].astype(str) + " " + df[1].astype(str), format="mixed")
        o = 2
    else:
        s = df[0].astype(str)
        ts = pd.to_datetime(s, format="%Y%m%d %H%M%S") if s.str.len().iloc[0] == 15 \
            else pd.to_datetime(s, format="mixed")
        o = 1
    return pd.DataFrame({"ts": ts, "open": df[o], "high": df[o + 1],
                         "low": df[o + 2], "close": df[o + 3]}), None


def to_utc(ts: pd.Series, source_tz: str) -> pd.DatetimeIndex:
    idx = pd.DatetimeIndex(ts)
    if source_tz == "utc":
        return idx.tz_localize("UTC")
    if source_tz == "ny_close":
        ny = (idx - pd.Timedelta(hours=7)).tz_localize(TZ_NY, ambiguous="NaT",
                                                      nonexistent="NaT")
        return ny.tz_convert("UTC")
    tz = "Europe/Athens" if source_tz == "eet" else source_tz
    return idx.tz_localize(tz, ambiguous="NaT", nonexistent="NaT").tz_convert("UTC")


def load_prices(path: str | Path, source_tz: str | None = None) -> pd.DataFrame:
    """Load a price file -> DataFrame[open, high, low, close] indexed by UTC timestamps."""
    path = Path(path)
    if path.suffix.lower() == ".parquet":
        df = pd.read_parquet(path)
        if df.index.tz is None:
            df.index = df.index.tz_localize("UTC")
        return df[["open", "high", "low", "close"]]

    frame, implied = _parse_frame(_read_text(path))
    tz = source_tz or implied
    if tz is None:
        raise ValueError(f"{path.name}: timezone not known - pass source_tz "
                         "('ny_close' for FTMO/MT5 server time, 'utc', ...)")
    frame.index = to_utc(frame.pop("ts"), tz)
    frame = frame[frame.index.notna()]
    frame = frame[~frame.index.duplicated(keep="last")].sort_index()
    if "vol" in frame.columns:  # Dukascopy-style flat zero-volume filler bars
        frame = frame[frame["vol"] > 0]
    frame = frame[["open", "high", "low", "close"]].astype(float)
    bad = (frame["high"] < frame["low"]) | frame.isna().any(axis=1)
    return frame[~bad]


def describe_session_gaps(df_utc: pd.DataFrame) -> pd.DataFrame:
    """Diagnostic for verifying the timezone: the hour (UTC) of the daily
    trading break in January vs July. For gold/US indices the break is
    17:00-18:00 New York, i.e. 22:00 UTC in January and 21:00 UTC in July."""
    idx = df_utc.index
    gaps = pd.Series(idx[1:] - idx[:-1], index=idx[:-1] + pd.Timedelta(minutes=1))
    big = gaps[(gaps >= pd.Timedelta(minutes=30)) & (gaps < pd.Timedelta(hours=6))]
    hrs = pd.DataFrame({"month": big.index.month, "hour_utc": big.index.hour})
    return (hrs[hrs.month.isin([1, 7])].groupby(["month", "hour_utc"]).size()
            .rename("count").reset_index().sort_values(["month", "count"],
                                                       ascending=[True, False]))


def resolution_minutes(df: pd.DataFrame) -> int:
    sec = df.index[:5000].values.astype("datetime64[s]").astype(np.int64)
    d = np.diff(sec) / 60
    return int(np.median(d)) if len(d) else 1
