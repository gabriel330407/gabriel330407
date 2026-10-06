"""Download Dukascopy M1 BID candles (UTC) and store one parquet per instrument-year.

Usage:
    python fetch_dukascopy.py XAUUSD US100 US500 EURUSD --start 2015 --end 2025

Needs network access to datafeed.dukascopy.com.
"""
from __future__ import annotations

import argparse
import lzma
import struct
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import date, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

from config import INSTRUMENTS

URL = "https://datafeed.dukascopy.com/datafeed/{sym}/{y}/{m:02d}/{d:02d}/BID_candles_min_1.bi5"
OUT = Path(__file__).parent / "data" / "duka"
REC = struct.Struct(">IIIIIf")  # sec offset, open, close, low, high, volume


def fetch_day(sym: str, day: date, div: float) -> np.ndarray | None:
    url = URL.format(sym=sym, y=day.year, m=day.month - 1, d=day.day)
    for attempt in range(5):
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                raw = r.read()
            break
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            time.sleep(2 ** attempt)
        except Exception:
            time.sleep(2 ** attempt)
    else:
        raise RuntimeError(f"failed: {url}")
    if not raw:
        return None
    data = lzma.decompress(raw)
    rows = np.array(list(REC.iter_unpack(data)), dtype=float)
    if rows.size == 0:
        return None
    base = pd.Timestamp(day).value // 10**9
    out = np.empty((len(rows), 6))
    out[:, 0] = base + rows[:, 0]
    out[:, 1] = rows[:, 1] / div  # open
    out[:, 2] = rows[:, 4] / div  # high
    out[:, 3] = rows[:, 3] / div  # low
    out[:, 4] = rows[:, 2] / div  # close
    out[:, 5] = rows[:, 5]
    return out


def fetch_year(key: str, year: int, workers: int = 12) -> Path | None:
    meta = INSTRUMENTS[key]
    path = OUT / f"{key}_{year}.parquet"
    if path.exists():
        return path
    end = min(date(year, 12, 31), date.today() - timedelta(days=1))
    days = [date(year, 1, 1) + timedelta(i) for i in range((end - date(year, 1, 1)).days + 1)]
    days = [d for d in days if d.weekday() != 5]  # Saturday never trades
    with ThreadPoolExecutor(workers) as ex:
        parts = [p for p in ex.map(lambda d: fetch_day(meta["duka"], d, meta["div"]), days)
                 if p is not None]
    if not parts:
        return None
    arr = np.vstack(parts)
    df = pd.DataFrame(arr[:, 1:], columns=["open", "high", "low", "close", "vol"],
                      index=pd.to_datetime(arr[:, 0].astype("int64"), unit="s", utc=True))
    df = df[df["vol"] > 0].sort_index()  # drop flat no-tick filler bars
    OUT.mkdir(parents=True, exist_ok=True)
    df.to_parquet(path)
    return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("instruments", nargs="+")
    ap.add_argument("--start", type=int, default=2015)
    ap.add_argument("--end", type=int, default=date.today().year)
    a = ap.parse_args()
    for key in a.instruments:
        for y in range(a.start, a.end + 1):
            t = time.time()
            p = fetch_year(key, y)
            print(f"{key} {y}: {p} ({time.time() - t:.0f}s)", flush=True)


if __name__ == "__main__":
    main()
