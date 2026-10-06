"""Hebrew, chart-executable wording for a setup row (from all_setups.csv / selected.csv)."""
from __future__ import annotations

import pandas as pd

WR = "WR20"  # median 19:00-21:00 range of the last 20 trading days
DAYS = {"Mon": "שני", "Tue": "שלישי", "Wed": "רביעי", "Thu": "חמישי", "Fri": "שישי"}
ANCHORS = {"NYopen": "פתיחת ניו-יורק (16:30)", "DayOpen": "פתיחת היום (01:00)",
           "60m": "המחיר לפני 60 דקות", "30m": "המחיר לפני 30 דקות"}
LEVELS = {"NY-morning high": "הגבוה של ניו-יורק מ-16:30 עד 19:00",
          "NY-morning low": "הנמוך של ניו-יורק מ-16:30 עד 19:00",
          "day high": "הגבוה של היום (01:00-19:00)", "day low": "הנמוך של היום (01:00-19:00)",
          "prev-day high": "הגבוה של אתמול", "prev-day low": "הנמוך של אתמול"}


def _stop(stop: str) -> str:
    if isinstance(stop, str) and stop.endswith("*WR20"):
        return f"{float(stop.split('*')[0]):g} × {WR}"
    return {"opp": "בצד השני של הטווח", "mid": "באמצע הטווח",
            "extreme": f"מעבר לקיצון של הפריצה + 0.05 × {WR}"}.get(stop, str(stop))


def rule_text(c: pd.Series) -> str:
    fam, rr = c["family"], c["rr"]
    tgt = f"יעד = {rr:g} × מרחק הסטופ (1:{rr:g}). מה שלא נסגר עד 21:00 - נסגר ידנית ב-21:00."
    day = "" if c.get("weekday", "all") == "all" else f" (רק בימי {DAYS[c['weekday']]})"
    if fam == "TIME":
        side = "לונג" if c["side"] == "long" else "שורט"
        return (f"בשעה {c['entry']}{day}: כניסה ב-Market ל{side}. "
                f"סטופ = {_stop(c['stop'])} מהכניסה. {tgt}")
    if fam == "MOM":
        x = float(c["min_move"])
        cond = "לפי כיוון התנועה" if x == 0 else f"רק אם התנועה גדולה מ-{x:g} × {WR}"
        act = "באותו כיוון של התנועה (המשכיות)" if c["mode"] == "follow" else "נגד התנועה (היפוך)"
        return (f"בשעה {c['entry']}: מודדים את התנועה מ{ANCHORS[c['anchor']]} ועד עכשיו, "
                f"{cond}. נכנסים ב-Market {act}. סטופ = {_stop(c['stop'])}. {tgt}")
    if fam == "ORB":
        k = int(c["or_min"])
        sides = {"both": "Buy Stop מעל הגבוה + Sell Stop מתחת לנמוך (הראשון שמופעל - מבטלים את השני)",
                 "long": "רק Buy Stop מעל הגבוה", "short": "רק Sell Stop מתחת לנמוך"}[c["sides"]]
        size = {"all": "", "small": f" רק אם הטווח קטן מ-0.35 × {WR}.",
                "large": f" רק אם הטווח גדול/שווה 0.35 × {WR}."}[c["or_size"]]
        return (f"מסמנים את הגבוה והנמוך של 19:00 עד 19:{k:02d}" if k < 60 else
                "מסמנים את הגבוה והנמוך של 19:00 עד 20:00") + \
            f".{size} {sides}, פעיל עד 20:30. סטופ {_stop(c['stop'])}. {tgt}"
    if fam == "ORFADE":
        k = int(c["or_min"])
        end = f"19:{k:02d}" if k < 60 else "20:00"
        return (f"מסמנים טווח 19:00-{end}. אחרי {end}, אם המחיר פורץ את הטווח ונר דקה נסגר חזרה "
                f"בתוכו - נכנסים בפתיחת הדקה הבאה נגד הפריצה (עד 20:30). "
                f"סטופ {_stop(c['stop'])}. {tgt}")
    if fam == "LEVEL":
        lv = LEVELS[c["level"]]
        up = "high" in c["level"]
        if c["mode"] == "breakout":
            order = "Buy Stop על הרמה" if up else "Sell Stop על הרמה"
        else:
            order = "Sell Limit על הרמה" if up else "Buy Limit על הרמה"
        return (f"רמה: {lv}. אם ב-19:00 המחיר עוד לא הגיע אליה - {order}, פעיל 19:00-20:30. "
                f"סטופ = {_stop(c['stop'])}. {tgt}")
    if fam == "PULLBACK":
        return (f"אם מ{ANCHORS[c['anchor']]} עד 19:00 המחיר זז לפחות {float(c['min_trend']):g} × {WR}: "
                f"Limit בכיוון המגמה, {float(c['pullback']):g} × {WR} מתחת (בלונג) / מעל (בשורט) "
                f"למחיר של 19:00, פעיל עד 20:30. סטופ = {_stop(c['stop'])}. {tgt}")
    return str(c.get("setup", ""))
