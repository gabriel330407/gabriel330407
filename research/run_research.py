"""Scan every setup on every instrument, validate out-of-sample, write a report.

Usage:
    python run_research.py XAUUSD US100 US500 EURUSD [--tz ny_close] [--oos 2022-01-01]

Data lookup per instrument KEY (first match wins):
    data/duka/KEY_*.parquet           (fetch_dukascopy.py, UTC)
    data/KEY*.csv / .txt / .zip       (MT5 / other export; set --tz)

Selection logic (all must hold):
    in-sample  (before --oos): avg R > 0.08, t-stat >= 2.0, >= 80 trades
    out-of-sample (after):     avg R > 0,    >= 30 trades
    whole period:              >= 65% of calendar years positive
Near-duplicate setups (R series correlation > 0.6) are collapsed to the best one.
"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import numpy as np
import pandas as pd

from config import INSTRUMENTS, OOS_START
from daymatrix import build_days
from loader import load_prices, resolution_minutes
from setups import all_setups
from stats import summarize, yearly_table

HERE = Path(__file__).parent
DATA = HERE / "data"
RES = HERE / "results"

SEL = dict(min_avg_is=0.10, min_t_is=2.5, min_n_is=100,       # in-sample discovery
           min_avg_oos=0.05, min_t_oos=1.0, min_n_oos=40,    # out-of-sample confirmation
           min_pos_years=0.70,                                # yearly consistency
           min_neighbors=0.60)                                # plateau, not a spike

PARAMS = ["family", "entry", "side", "stop", "rr", "weekday", "anchor", "min_move", "mode",
          "or_min", "sides", "or_size", "level", "min_trend", "pullback"]


def load_instrument(key: str, tz: str | None) -> pd.DataFrame:
    duka = sorted((DATA / "duka").glob(f"{key}_*.parquet"))
    if duka:
        return pd.concat([load_prices(p) for p in duka]).sort_index()
    files = sorted(p for ext in ("csv", "txt", "zip") for p in DATA.glob(f"{key}*.{ext}"))
    if not files:
        raise FileNotFoundError(f"no data for {key} in {DATA}")
    df = pd.concat([load_prices(p, tz) for p in files]).sort_index()
    return df[~df.index.duplicated(keep="last")]


def describe(cfg: dict) -> str:
    keys = [k for k in cfg if k not in ("family", "instrument")]
    return cfg["family"] + " | " + ", ".join(f"{k}={cfg[k]}" for k in keys)


def scan(key: str, tz: str | None, oos: str, cost_as: str | None = None):
    t0 = time.time()
    df = load_instrument(key, tz)
    res = resolution_minutes(df)
    days = build_days(df, res=res)
    meta = INSTRUMENTS.get(cost_as or key, {})
    cost, slip = meta.get("cost", 0.0), meta.get("slip", 0.0)
    print(f"[{key}] {len(df):,} bars (M{res}), {len(days.dates)} days "
          f"{days.dates[0].date()} .. {days.dates[-1].date()}, cost={cost} slip={slip}", flush=True)
    rows, series = [], []
    for cfg, r in all_setups(days, (cost, slip)):
        st = summarize(r, days.dates, oos)
        rows.append({"instrument": key, **cfg, **st, "setup": describe(cfg)})
        series.append(r.astype(np.float32))
    tab = pd.DataFrame(rows)
    tab["neighbors_pos"] = neighbor_share(tab)
    print(f"[{key}] {len(tab)} setups scanned in {time.time() - t0:.0f}s", flush=True)
    return days, tab, np.vstack(series)


def neighbor_share(tab: pd.DataFrame) -> pd.Series:
    """Share of sibling setups (same rule, other stop size / R multiple) that are
    also profitable. A real effect should not depend on one exact stop size."""
    key = [c for c in PARAMS if c in tab.columns and c not in ("stop", "rr")]
    sig = tab[key].astype(object).where(tab[key].notna(), "-").astype(str).agg("|".join, axis=1)
    g = (tab["avg_r"] > 0).astype(int).groupby(sig)
    tot, cnt = g.transform("sum"), g.transform("size")
    return (tot - (tab["avg_r"] > 0)) / (cnt - 1).clip(lower=1)


def passes_is(tab):
    return ((tab.avg_is > SEL["min_avg_is"]) & (tab.t_is >= SEL["min_t_is"]) &
            (tab.n_is >= SEL["min_n_is"]))


def select(tab: pd.DataFrame, R: np.ndarray) -> pd.DataFrame:
    ok = (passes_is(tab) & (tab.avg_oos > SEL["min_avg_oos"]) & (tab.t_oos >= SEL["min_t_oos"]) &
          (tab.n_oos >= SEL["min_n_oos"]) & (tab.pos_years >= SEL["min_pos_years"]) &
          (tab.neighbors_pos >= SEL["min_neighbors"]))
    cand = tab[ok].copy()
    cand["score"] = cand["t"] + cand["t_oos"].clip(upper=4)
    cand = cand.sort_values("score", ascending=False)
    kept: list[int] = []
    Z = np.nan_to_num(R, nan=0.0)
    for i in cand.index:   # collapse near-duplicates (same trades in disguise)
        if all(abs(np.corrcoef(Z[i], Z[j])[0, 1]) < 0.6 for j in kept):
            kept.append(i)
    return cand.loc[kept]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("instruments", nargs="+")
    ap.add_argument("--tz", default=None, help="source timezone for CSV files (ny_close/utc/...)")
    ap.add_argument("--oos", default=OOS_START)
    ap.add_argument("--tag", default="")
    ap.add_argument("--data", default=None, help="data directory (default research/data)")
    ap.add_argument("--cost-as", default=None, help="use another instrument's cost model")
    a = ap.parse_args()
    global DATA
    if a.data:
        DATA = Path(a.data)
    out = RES / (a.tag or "latest")
    out.mkdir(parents=True, exist_ok=True)

    all_tabs, picks, store = [], [], {}
    for key in a.instruments:
        days, tab, R = scan(key, a.tz, a.oos, a.cost_as)
        all_tabs.append(tab)
        sel = select(tab, R)
        n_is_pass = int(passes_is(tab).sum())
        n_oos_conf = int((passes_is(tab) & (tab.avg_oos > 0)).sum())
        print(f"[{key}] passed in-sample: {n_is_pass}, of those positive OOS: {n_oos_conf}, "
              f"final (after robustness + dedup): {len(sel)}", flush=True)
        picks.append(sel)
        for i in sel.index:
            store[f"{key}#{i}"] = (days.dates, R[i])
        np.save(out / f"{key}_R.npy", R)
        pd.Series(days.dates).to_csv(out / f"{key}_dates.csv", index=False)

    tab = pd.concat(all_tabs, ignore_index=True)
    tab.to_csv(out / "all_setups.csv", index=False)
    sel = pd.concat(picks)
    sel.to_csv(out / "selected.csv", index=False)

    with open(out / "selected_yearly.md", "w") as fh:
        for (key, i), row in zip([k.split("#") for k in store], sel.itertuples()):
            dates, r = store[f"{key}#{i}"]
            fh.write(f"### {key}: {row.setup}\n\n")
            fh.write(yearly_table(r, dates).to_markdown() + "\n\n")
    with open(out / "run.json", "w") as fh:
        json.dump(dict(instruments=a.instruments, oos=a.oos, selection=SEL), fh, indent=1)
    cols = ["instrument", "setup", "n", "per_year", "win", "avg_r", "t", "avg_is", "avg_oos",
            "t_oos", "pos_years", "max_dd", "max_lose_streak"]
    with pd.option_context("display.width", 250, "display.max_colwidth", 120):
        print(sel[cols].round(3).to_string(index=False))


if __name__ == "__main__":
    main()
