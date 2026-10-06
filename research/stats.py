"""Performance statistics for a per-day R series (NaN = no trade that day)."""
from __future__ import annotations

import numpy as np
import pandas as pd


def _t(x: np.ndarray) -> float:
    if len(x) < 3:
        return np.nan
    sd = x.std(ddof=1)
    return float(x.mean() / sd * np.sqrt(len(x))) if sd > 0 else np.nan


def max_dd(x: np.ndarray) -> float:
    if len(x) == 0:
        return 0.0
    eq = np.cumsum(x)
    return float((np.maximum.accumulate(np.concatenate([[0], eq]))[1:] - eq).max())


def max_losing_streak(x: np.ndarray) -> int:
    best = cur = 0
    for v in x:
        cur = cur + 1 if v < 0 else 0
        best = max(best, cur)
    return best


def summarize(r: np.ndarray, dates: pd.DatetimeIndex, oos_start: str) -> dict:
    m = np.isfinite(r)
    x = r[m]
    dt = dates[m]
    is_m = dt < pd.Timestamp(oos_start)
    xi, xo = x[is_m], x[~is_m]
    years = pd.Series(x, index=dt.year).groupby(level=0).sum() if len(x) else pd.Series(dtype=float)
    span_years = max((dates[-1] - dates[0]).days / 365.25, 1e-9)
    gp, gl = x[x > 0].sum(), -x[x < 0].sum()
    return dict(
        n=len(x), per_year=len(x) / span_years,
        win=float((x > 0).mean()) if len(x) else np.nan,
        avg_r=float(x.mean()) if len(x) else np.nan, sum_r=float(x.sum()),
        pf=float(gp / gl) if gl > 0 else np.nan, t=_t(x),
        n_is=len(xi), avg_is=float(xi.mean()) if len(xi) else np.nan, t_is=_t(xi),
        n_oos=len(xo), avg_oos=float(xo.mean()) if len(xo) else np.nan, t_oos=_t(xo),
        pos_years=float((years > 0).mean()) if len(years) else np.nan,
        worst_year=float(years.min()) if len(years) else np.nan,
        max_dd=max_dd(x), max_lose_streak=max_losing_streak(x),
    )


def yearly_table(r: np.ndarray, dates: pd.DatetimeIndex) -> pd.DataFrame:
    m = np.isfinite(r)
    s = pd.Series(r[m], index=dates[m])
    g = s.groupby(s.index.year)
    return pd.DataFrame({"trades": g.size(), "win%": (g.apply(lambda v: (v > 0).mean()) * 100).round(0),
                         "sum_R": g.sum().round(1), "avg_R": g.mean().round(2)})
