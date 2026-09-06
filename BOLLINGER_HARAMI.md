# 📉 Bollinger Harami Ichimoku

A mean-reversion / reversal strategy for TradingView, built around a **Harami**
candlestick that prints **outside a Bollinger Band**, with the **Ichimoku
Baseline (Kijun-sen)** as the profit target. Designed for the **5-minute chart**
(works on any timeframe).

## 📦 Files

| File | Purpose |
|------|---------|
| `strategy/bollinger_harami_strategy.pine` | **Backtest strategy** – win rate, PnL, drawdown in the Strategy Tester |
| `indicator/bollinger_harami_indicator.pine` | **Signal indicator** – prints BUY/SELL labels + levels, and alerts |

Both use the exact same signal logic, so labels on the indicator line up with
fills in the strategy.

## 🎯 The Rules

**Indicators (standard setups):**
- Bollinger Bands `(20, 2)` — the **basis / middle line is turned OFF**.
- Ichimoku — only the **Baseline (Kijun-sen, length 26)** is kept and used.

**Signal — Harami pattern (long *and* short):**

A Harami is a large candle followed by a smaller candle whose real body is
fully contained inside the first candle's body — here the second body must be
**30–70% of the first body** (configurable).

| Direction | 1st (large) candle | 2nd (small) candle | Extra condition |
|-----------|--------------------|--------------------|-----------------|
| **Long**  | bearish            | bullish, inside 1st | 1st candle **closes below the lower band** |
| **Short** | bullish            | bearish, inside 1st | 1st candle **closes above the upper band** |

Entry is taken on the **close of the 2nd candle** (the confirmation bar).

**Exit:**
- Price reaches the **Ichimoku Baseline (Kijun-sen)** → take profit.

**Stop loss (dynamic):**
- **Long:** most recent **swing low** (lowest low over the lookback) − ATR buffer.
- **Short:** most recent **swing high** (highest high over the lookback) + ATR buffer.

## ⚙️ Key Inputs

| Input | Default | Notes |
|-------|---------|-------|
| BB Length / Mult | `20` / `2.0` | Standard Bollinger settings |
| Show BB Basis | `off` | Middle line hidden per spec |
| Baseline (Kijun) Length | `26` | Ichimoku baseline / exit target |
| Require 2nd candle opposite color | `on` | Classic Harami; turn off to relax |
| 2nd body min / max % of 1st body | `30%` / `70%` | Second candle's body must be 30–70% of the first's |
| Min 1st-candle body vs range | `0` (off) | Optional filter for a *strong* first candle |
| Swing Lookback (stop) | `10` bars | Where the dynamic stop is measured |
| Stop buffer (× ATR) | `1.0` | Padding beyond the swing (raise for a wider stop) |
| Exit at Ichimoku Baseline | `on` | Uncheck to let the stop run alone |

## 🚀 Setup

### Backtest
1. TradingView → open a chart on the **5-minute** timeframe.
2. Pine Editor → paste `strategy/bollinger_harami_strategy.pine` → Save → Add to Chart.
3. Open the **Strategy Tester** tab and review win rate / profit factor / drawdown.
4. Tune the swing lookback, ATR buffer, and the "opposite color" / min-body
   filters to fit the instrument.

### Live labels + alerts
1. New/same chart on 5-minute → Pine Editor → paste
   `indicator/bollinger_harami_indicator.pine` → Save → Add.
2. BUY/SELL labels print on the confirmation bar, each showing entry, stop, and
   the baseline target.
3. Right-click chart → **Add Alert** → Condition: `Bollinger Harami Ichimoku - Signals`
   → pick `BB-Harami LONG` / `BB-Harami SHORT` → **Once per bar close**.

## 🛡️ Risk Disclaimer

This is a technical trading tool, not financial advice. Trading carries
substantial risk of loss. Always paper-trade and validate on the Strategy
Tester before risking real capital.
