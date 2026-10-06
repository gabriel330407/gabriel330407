"""Vectorised trade simulation inside the 19:00-21:00 window.

One trade max per day per setup. Rules:
  * fixed stop distance s, fixed target RR*s, everything flat at 21:00
  * after the entry minute, if stop and target are both touched in the same
    minute -> counted as LOSS (conservative)
  * the entry minute itself (stop/limit orders filled inside a bar) is walked
    with the usual OHLC path heuristic: bullish bar O->L->H->C, bearish bar
    O->H->L->C; only the part of the path after the fill can hit stop/target
  * limit orders only fill if price trades THROUGH the level by `penetration`
  * round-trip cost (spread + commission) is subtracted in R units
"""
from __future__ import annotations

import numpy as np

from daymatrix import Days


def _entry_bar_outcome(o, h, l, c, px, dr, sl, tp):
    """+1 target, -1 stop, 0 undecided - using the part of the bar after the fill."""
    bull = c >= o
    up_leg = px > o          # filled while price was rising (towards H)
    dn_leg = px < o          # filled while price was falling (towards L)
    nan = np.full_like(o, np.nan)
    # remaining path points after the fill (monotonic legs between them)
    p1 = np.where(bull, np.where(up_leg, h, l), np.where(dn_leg, l, h))
    p2 = np.where(bull, np.where(up_leg, c, h), np.where(dn_leg, c, l))
    p3 = np.where(bull, np.where(up_leg, nan, c), np.where(dn_leg, nan, c))
    res = np.zeros(len(o))
    for p in (p1, p2, p3):
        undecided = res == 0
        stop = undecided & ((p - sl) * dr <= 0)
        tgt = undecided & ((p - tp) * dr >= 0) & ~stop
        res[stop] = -1
        res[tgt] = 1
    return res


def simulate(d: Days, entry_idx: np.ndarray, entry_px: np.ndarray, direction: np.ndarray,
             stop_dist: np.ndarray, rr: float, cost: float, intrabar: bool,
             slip: float = 0.0, stop_entry: bool = False) -> np.ndarray:
    """Returns net R per day (NaN = no trade).
    intrabar=False: market order at the OPEN of minute entry_idx.
    intrabar=True : pending order filled inside minute entry_idx at entry_px.
    slip: slippage (price) charged on stop-loss exits, and on the entry too
    when stop_entry=True (breakout stop orders)."""
    n, m = d.H.shape
    out = np.full(n, np.nan)
    stop_dist = np.broadcast_to(stop_dist, (n,))
    direction = np.broadcast_to(direction, (n,))
    take = (entry_idx >= 0) & np.isfinite(stop_dist) & (stop_dist > 0) & np.isfinite(entry_px) \
        & (direction != 0)
    if not take.any():
        return out
    rows = np.flatnonzero(take)
    e = entry_idx[rows]
    px = entry_px[rows]
    dr = direction[rows].astype(float)
    s = stop_dist[rows]
    O, H, L, C = d.O[rows], d.H[rows], d.L[rows], d.C[rows]
    sl = px - dr * s
    tp = px + dr * rr * s

    cols = np.arange(m)[None, :]
    after = (cols > e[:, None]) if intrabar else (cols >= e[:, None])
    dcol = dr[:, None]
    adv = np.where(dcol > 0, L, H)
    fav = np.where(dcol > 0, H, L)
    stop_hit = after & ((adv - sl[:, None]) * dcol <= 0)
    tgt_hit = after & ((fav - tp[:, None]) * dcol >= 0)
    fs = np.where(stop_hit.any(1), stop_hit.argmax(1), m)
    ft = np.where(tgt_hit.any(1), tgt_hit.argmax(1), m)
    if intrabar:
        k = np.arange(len(rows))
        eb = _entry_bar_outcome(O[k, e], H[k, e], L[k, e], C[k, e], px, dr, sl, tp)
        fs = np.where(eb < 0, e, fs)
        ft = np.where(eb > 0, e, np.where(eb < 0, m, ft))

    r = np.empty(len(rows))
    lose = (fs < m) & (fs <= ft)
    win = (ft < m) & ~lose
    flat = ~lose & ~win
    if lose.any():  # stop fill: at the stop, or at the bar open if it gapped through
        i = np.flatnonzero(lose)
        o = O[i, fs[i]]
        gap = ((o - sl[i]) * dr[i] < 0) & (fs[i] > e[i])
        fill = np.where(gap, o, sl[i])
        r[i] = (fill - px[i]) * dr[i] / s[i]
    r[win] = rr
    if flat.any():
        i = np.flatnonzero(flat)
        r[i] = (C[i, -1] - px[i]) * dr[i] / s[i]
    r -= (cost + (slip if stop_entry else 0.0)) / s
    r[lose] -= slip / s[lose]
    out[rows] = r
    return out


def market_entry_at(d: Days, minute: int):
    """Market order at the open of window minute `minute` (0 = 19:00)."""
    n = len(d.dates)
    return np.full(n, minute, dtype=int), d.O[:, minute].copy()


def first_touch(d: Days, level: np.ndarray, side: int, start: int, last: int,
                penetration: float | np.ndarray = 0.0):
    """First minute in [start, last] whose high (side=+1) / low (side=-1)
    reaches `level` (+/- penetration). Returns (idx or -1, fill price).
    Fill = level, or the bar open if it opened beyond the level.
    Use penetration > 0 for LIMIT orders (price must trade through)."""
    n, m = d.H.shape
    cols = np.arange(m)[None, :]
    win = (cols >= start) & (cols <= last)
    lv = level[:, None]
    pen = np.broadcast_to(penetration, (n,))[:, None]
    hit = win & ((d.H >= lv + pen) if side > 0 else (d.L <= lv - pen))
    has = hit.any(1) & np.isfinite(level)
    idx = np.where(has, hit.argmax(1), -1)
    o = d.O[np.arange(n), np.clip(idx, 0, m - 1)]
    fill = np.where(side > 0, np.maximum(level, o), np.minimum(level, o))
    return idx, np.where(has, fill, np.nan)
