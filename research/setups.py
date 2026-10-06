"""Hypothesis families for MANUAL trades inside 19:00-21:00 Israel time.

Every setup is something a human can execute from a chart with pending or
market orders: a time, a level, a direction rule, a stop, a fixed 1:R target.
Stops are sized from WR20 = median 19:00-21:00 range of the previous 20 days
(known before the session starts), or from a structural level.

Minute indices are relative to 19:00 (0 = 19:00, 60 = 20:00, 90 = 20:30).
"""
from __future__ import annotations

from typing import Iterator

import numpy as np

from config import LAST_ENTRY, WIN_START
from daymatrix import Days
from simulate import first_touch, market_entry_at, simulate

LAST = LAST_ENTRY - WIN_START          # 90 -> last entry minute 20:30
F_STOPS = (0.2, 0.3, 0.45)            # stop = f * WR20
RRS = (1.5, 2.0)
WEEKDAYS = ("all", 0, 1, 2, 3, 4)


def hhmm(minute: int) -> str:
    t = WIN_START + minute
    return f"{t // 60:02d}:{t % 60:02d}"


def _price_back(d: Days, T: int, back: int) -> np.ndarray:
    """Price `back` minutes before window minute T (uses pre-window anchors)."""
    k = T - back
    if k >= 0:
        return d.O[:, k]
    anchor = {-60: "p_1800", -30: "p_1830"}.get(k)
    if anchor is None:
        raise ValueError(k)
    return d.f[anchor].to_numpy()


# --------------------------------------------------------------------------- A
def fam_time(d: Days, cm: tuple) -> Iterator[tuple[dict, np.ndarray]]:
    """Pure time-of-day bias: market order at a fixed minute, fixed direction."""
    cost, slip = cm
    wr = d.f["wr20"].to_numpy()
    for T in (0, 15, 30, 45, 60, 75, 90):
        idx, px = market_entry_at(d, T)
        for dr in (1, -1):
            for f in F_STOPS:
                for rr in RRS:
                    r = simulate(d, idx, px, np.full(len(idx), dr), f * wr, rr, cost, False, slip)
                    yield dict(family="TIME", entry=hhmm(T), side="long" if dr > 0 else "short",
                               stop=f"{f}*WR20", rr=rr), r


# --------------------------------------------------------------------------- B
def fam_momentum(d: Days, cm: tuple):
    """At time T: if price moved >= x*WR20 since an anchor, follow or fade it."""
    cost, slip = cm
    wr = d.f["wr20"].to_numpy()
    anchors = {
        "NYopen": lambda T: d.f["ny_open"].to_numpy(),
        "DayOpen": lambda T: d.f["day_open"].to_numpy(),
        "60m": lambda T: _price_back(d, T, 60),
        "30m": lambda T: _price_back(d, T, 30),
    }
    for T in (0, 30, 60, 90):
        idx, px = market_entry_at(d, T)
        for an, fn in anchors.items():
            move = (px - fn(T)) / wr
            for x in (0.0, 0.5, 1.0):
                sig = np.where(move > x, 1, np.where(move < -x, -1, 0)) if x > 0 \
                    else np.sign(move).astype(int)
                for mode in ("follow", "fade"):
                    dr = sig if mode == "follow" else -sig
                    e = np.where(dr != 0, idx, -1)
                    for f in F_STOPS:
                        for rr in RRS:
                            r = simulate(d, e, px, dr, f * wr, rr, cost, False, slip)
                            yield dict(family="MOM", entry=hhmm(T), anchor=an, min_move=x,
                                       mode=mode, stop=f"{f}*WR20", rr=rr), r


# --------------------------------------------------------------------------- C
def fam_orb(d: Days, cm: tuple):
    """Opening-range breakout of the window's own first k minutes."""
    cost, slip = cm
    wr = d.f["wr20"].to_numpy()
    n = len(d.dates)
    for k in (15, 30, 60):
        orh = d.H[:, :k].max(1)
        orl = d.L[:, :k].min(1)
        size = (orh - orl) / wr
        il, pl = first_touch(d, orh + 1e-12, +1, k, LAST)
        is_, ps = first_touch(d, orl - 1e-12, -1, k, LAST)
        for sides in ("both", "long", "short"):
            lo = il >= 0 if sides != "short" else np.zeros(n, bool)
            so = is_ >= 0 if sides != "long" else np.zeros(n, bool)
            take_long = lo & (~so | (il <= is_))   # same-minute double break -> long, stop
            take_short = so & ~take_long           # will be checked on the bar (conservative)
            dr = np.where(take_long, 1, np.where(take_short, -1, 0))
            e = np.where(take_long, il, np.where(take_short, is_, -1))
            px = np.where(take_long, pl, ps)
            for stop_mode in ("opp", "mid", "0.3*WR20"):
                if stop_mode == "opp":
                    s = np.where(dr > 0, px - orl, orh - px)
                elif stop_mode == "mid":
                    mid = (orh + orl) / 2
                    s = np.where(dr > 0, px - mid, mid - px)
                else:
                    s = 0.3 * wr
                for size_f in ("all", "small", "large"):
                    keep = np.ones(n, bool) if size_f == "all" else \
                        (size < 0.35 if size_f == "small" else size >= 0.35)
                    ee = np.where(keep, e, -1)
                    for rr in RRS:
                        r = simulate(d, ee, px, dr, s, rr, cost, True, slip, stop_entry=True)
                        yield dict(family="ORB", or_min=k, sides=sides, stop=stop_mode,
                                   or_size=size_f, rr=rr), r


# --------------------------------------------------------------------------- D
def fam_or_fade(d: Days, cm: tuple):
    """False breakout of the window opening range: price pokes beyond the OR,
    then a minute closes back inside -> enter against the poke at next open."""
    cost, slip = cm
    wr = d.f["wr20"].to_numpy()
    n, m = d.H.shape
    cols = np.arange(m)[None, :]
    for k in (15, 30, 60):
        orh = d.H[:, :k].max(1)[:, None]
        orl = d.L[:, :k].min(1)[:, None]
        poke_up = np.maximum.accumulate(np.where(cols >= k, d.H, -np.inf), axis=1) > orh
        poke_dn = np.minimum.accumulate(np.where(cols >= k, d.L, np.inf), axis=1) < orl
        back_dn = poke_up & (d.C < orh) & (cols >= k) & (cols < LAST)   # short signal
        back_up = poke_dn & (d.C > orl) & (cols >= k) & (cols < LAST)   # long signal
        ss = np.where(back_dn.any(1), back_dn.argmax(1), m)
        ls = np.where(back_up.any(1), back_up.argmax(1), m)
        dr = np.where((ss < m) & (ss <= ls), -1, np.where(ls < m, 1, 0))
        sig = np.where(dr < 0, ss, ls)
        e = np.where(dr != 0, sig + 1, -1)
        e = np.where(e >= m, -1, e)
        rows = np.arange(n)
        px = d.O[rows, np.clip(e, 0, m - 1)]
        # extreme of the poke up to the signal bar
        hi_sofar = np.maximum.accumulate(d.H, axis=1)[rows, np.clip(sig, 0, m - 1)]
        lo_sofar = np.minimum.accumulate(d.L, axis=1)[rows, np.clip(sig, 0, m - 1)]
        for stop_mode in ("extreme", "0.3*WR20"):
            if stop_mode == "extreme":
                buf = 0.05 * wr
                s = np.where(dr < 0, hi_sofar + buf - px, px - (lo_sofar - buf))
            else:
                s = 0.3 * wr
            for rr in RRS:
                r = simulate(d, e, px, dr, s, rr, cost, False, slip)
                yield dict(family="ORFADE", or_min=k, stop=stop_mode, rr=rr), r


# --------------------------------------------------------------------------- E
def fam_levels(d: Days, cm: tuple):
    """First touch, inside the window, of a level fixed before 19:00:
    breakout (stop order through it) or fade (limit order against it)."""
    cost, slip = cm
    wr = d.f["wr20"].to_numpy()
    p0 = d.f["p0"].to_numpy()
    levels = {
        "NY-morning high": ("am_high", +1), "NY-morning low": ("am_low", -1),
        "day high": ("day_high", +1), "day low": ("day_low", -1),
        "prev-day high": ("pd_high", +1), "prev-day low": ("pd_low", -1),
    }
    for name, (col, side) in levels.items():
        lv = d.f[col].to_numpy().astype(float)
        valid = (p0 < lv) if side > 0 else (p0 > lv)       # level still ahead at 19:00
        lv = np.where(valid, lv, np.nan)
        touches = {"breakout": first_touch(d, lv, side, 0, LAST),            # stop order
                   "fade": first_touch(d, lv, side, 0, LAST, penetration=cost)}  # limit order
        for mode, (idx, px) in touches.items():
            dr = np.full(len(idx), side if mode == "breakout" else -side)
            for f in F_STOPS:
                for rr in RRS:
                    r = simulate(d, idx, px, dr, f * wr, rr, cost, True, slip,
                                 stop_entry=(mode == "breakout"))
                    yield dict(family="LEVEL", level=name, mode=mode, stop=f"{f}*WR20", rr=rr), r


# --------------------------------------------------------------------------- F
def fam_pullback(d: Days, cm: tuple):
    """Trend into 19:00 (from NY open or day open) >= x*WR20; buy/sell a
    pullback of y*WR20 from the 19:00 price with a limit order."""
    cost, slip = cm
    wr = d.f["wr20"].to_numpy()
    p0 = d.f["p0"].to_numpy()
    for an, col in (("NYopen", "ny_open"), ("DayOpen", "day_open")):
        move = (p0 - d.f[col].to_numpy()) / wr
        for x in (0.5, 1.0, 1.5):
            trend = np.where(move >= x, 1, np.where(move <= -x, -1, 0))
            for y in (0.1, 0.2, 0.3):
                lvl = np.where(trend != 0, p0 - trend * y * wr, np.nan)
                il, pl = first_touch(d, np.where(trend > 0, lvl, np.nan), -1, 0, LAST, cost)
                is_, ps = first_touch(d, np.where(trend < 0, lvl, np.nan), +1, 0, LAST, cost)
                e = np.where(trend > 0, il, np.where(trend < 0, is_, -1))
                px = np.where(trend > 0, pl, ps)
                for f in F_STOPS:
                    for rr in RRS:
                        r = simulate(d, e, px, trend, f * wr, rr, cost, True, slip)
                        yield dict(family="PULLBACK", anchor=an, min_trend=x, pullback=y,
                                   stop=f"{f}*WR20", rr=rr), r


FAMILIES = (fam_time, fam_momentum, fam_orb, fam_or_fade, fam_levels, fam_pullback)


def all_setups(d: Days, cm: tuple):
    """Yields (cfg, R). TIME setups are additionally split by weekday."""
    wd = d.f["weekday"].to_numpy()
    for fam in FAMILIES:
        for cfg, r in fam(d, cm):
            if cfg["family"] == "TIME":
                for w in WEEKDAYS:
                    if w == "all":
                        yield {**cfg, "weekday": "all"}, r
                    else:
                        yield {**cfg, "weekday": "Mon Tue Wed Thu Fri".split()[w]}, \
                            np.where(wd == w, r, np.nan)
            else:
                yield {**cfg, "weekday": "all"}, r
