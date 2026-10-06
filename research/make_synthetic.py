"""Synthetic M1 data to validate the research pipeline (not market data!).

  null : random walk with realistic intraday volatility + vol clustering.
         A sound pipeline must find (almost) nothing here.
  edge : same, plus a planted effect - between 19:30 and 20:30 Israel time
         price drifts in the direction of the NY-open->19:30 move.
         A sound pipeline must find it.
"""
import argparse
from pathlib import Path

import numpy as np
import pandas as pd

from config import TZ_LOCAL


def make(kind: str, seed: int, start="2015-01-01", end="2025-09-30", p0=1200.0):
    rng = np.random.default_rng(seed)
    idx = pd.date_range(start, end, freq="1min", tz="UTC")
    idx = idx[(idx.dayofweek < 5) & (idx.hour != 21)]           # daily break 21-22 UTC
    loc = idx.tz_convert(TZ_LOCAL)
    tod = (loc.hour * 60 + loc.minute).to_numpy()
    date = loc.tz_localize(None).normalize()
    # intraday volatility profile (Israel minutes): Asia low, London, NY peaks
    h = tod / 60.0
    season = (0.5 + 0.6 * np.exp(-((h - 10) / 1.2) ** 2) + 1.2 * np.exp(-((h - 16.6) / 0.7) ** 2)
              + 0.6 * np.exp(-((h - 18.0) / 1.5) ** 2))
    # daily vol clustering
    ud = pd.Index(date.unique())
    lv = np.zeros(len(ud))
    for i in range(1, len(ud)):
        lv[i] = 0.97 * lv[i - 1] + 0.2 * rng.standard_normal()
    dvol = 0.009 * np.exp(lv - lv.std() ** 2 / 2)              # ~0.9% daily
    di = ud.get_indexer(date)
    sig = dvol[di] * season / np.sqrt((season ** 2).sum() / len(ud))
    # fat tails: random per-minute variance scale (student-t like mixture)
    sig = sig * np.sqrt(3.0 / rng.chisquare(5, len(idx)))
    k = 10  # path-consistent bars from 10 sub-steps per minute
    sub = rng.standard_normal((len(idx), k)) * (sig / np.sqrt(k))[:, None]
    ret = sub.sum(1)
    if kind == "edge":
        frame = pd.DataFrame({"d": di, "tod": tod, "r": ret})
        cum = frame.groupby("d")["r"].cumsum().to_numpy()
        at = lambda t: pd.Series(np.where(tod == t, cum, np.nan)).groupby(di).max()
        move = (at(19 * 60 + 29) - at(16 * 60 + 29)).reindex(range(len(ud))).to_numpy()
        zone = (tod >= 19 * 60 + 30) & (tod < 20 * 60 + 30)
        drift = np.where(zone, 0.08 * dvol[di] / 60 * np.sign(np.nan_to_num(move[di])), 0.0)
        sub += (drift / k)[:, None]
        ret = sub.sum(1)
    path = np.concatenate([np.zeros((len(idx), 1)), np.cumsum(sub, 1)], 1)
    logc = np.cumsum(ret)
    logo = np.concatenate([[0.0], logc[:-1]])
    open_ = p0 * np.exp(logo)
    df = pd.DataFrame({"open": open_, "high": p0 * np.exp(logo + path.max(1)),
                       "low": p0 * np.exp(logo + path.min(1)), "close": p0 * np.exp(logc),
                       "vol": 1.0}, index=idx)
    return df.round(2)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    a = ap.parse_args()
    out = Path(a.out) / "duka"
    out.mkdir(parents=True, exist_ok=True)
    for kind, seed in (("null", 1), ("edge", 2)):
        df = make(kind, seed)
        key = f"SYN{kind.upper()}"
        for y, g in df.groupby(df.index.year):
            g.to_parquet(out / f"{key}_{y}.parquet")
        print(key, len(df))
