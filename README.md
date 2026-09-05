# 🌊 WaveBot - Automated Forex Trading System for TradingView

Multi-indicator confluence strategy for TradingView Premium, fully automated
across 8 Forex pairs with Multi-Timeframe analysis.

## 📦 Package Contents

| File | Purpose |
|------|---------|
| `strategy/wave_bot_strategy.pine` | **Backtest strategy** - historical win rate, PnL, drawdown |
| `scanner/wave_bot_scanner.pine`   | **8-pair scanner** - one chart watches all pairs, 2-position cap |
| `indicator/wave_bot_alerts.pine`  | **Per-chart alerts** - detailed per-pair alerts + trailing stop |

## 🎯 Strategy Specs

- **Take Profit:** 3%
- **Stop Loss:** 1.5%
- **Reward:Risk:** 2:1 (breakeven at 34% win rate → targeting 62%+)
- **Position Size:** 30% of equity
- **Max Concurrent Positions:** 2
- **Cooldown:** 3 bars between trades
- **Session:** London + NY overlap (12:00-17:00 exchange time) + no Friday PM

## 🧠 Confluence Logic (6-point scoring, minimum 5/6 required)

| # | Condition | Long | Short |
|---|-----------|------|-------|
| 1 | EMA50 vs EMA200 trend + price above/below EMA50 | ✅ | ✅ |
| 2 | HTF (H4) trend alignment (EMA50 > EMA200 + close > EMA200) | ✅ | ✅ |
| 3 | RSI(14) in pullback zone (40-65 long / 35-60 short) | ✅ | ✅ |
| 4 | MACD line vs signal + rising histogram | ✅ | ✅ |
| 5 | ADX > 22 + DI alignment | ✅ | ✅ |
| 6 | Stochastic cross + not overbought/oversold | ✅ | ✅ |

**Volatility filter:** ATR must be < 1.5× its 50-bar average (avoid chop/news spikes).

## 🌐 Selected Forex Pairs (8 tabs)

`EURUSD` · `GBPUSD` · `USDJPY` · `AUDUSD` · `USDCAD` · `NZDUSD` · `EURJPY` · `GBPJPY`

> Using OANDA prefix by default. Change to your broker's tickers in the inputs
> if needed (e.g., `FX:EURUSD`, `FX_IDC:EURUSD`).

## ⏱️ Timeframes (Multi-TF Automated)

- **Primary scan:** H1 (signal generation)
- **Higher TF filter:** H4 (trend context)
- All configurable per script.

## 🚀 Setup Guide

### 1. Backtest (validate win rate first)

1. Open TradingView, load any chart.
2. Pine Editor → paste `strategy/wave_bot_strategy.pine` → Save → Add to Chart.
3. Open **Strategy Tester** tab → verify historical win rate / profit factor /
   drawdown on each of the 8 pairs over 1-2 years.
4. Tune `Minimum Confluence Score` (5-6 = selective / higher win rate).

### 2. Live Scanner (single tab watches all 8 pairs)

1. New chart → Pine Editor → paste `scanner/wave_bot_scanner.pine` → Save → Add.
2. In the indicator settings, adjust the 8 pairs if your broker uses different
   prefixes.
3. Right-click the chart → **Add Alert** → Condition: `WaveBot Scanner` →
   `WaveBot: ANY signal (capacity available)`.
4. Alert options: **Once per bar close**, **Webhook URL** (optional, for
   3commas / Telegram bot / your own server).
5. The scanner tracks up to 2 "virtual" open positions and **only fires alerts
   when capacity is available** - respecting your max-2 rule.

### 3. Per-Chart Alerts (the 8 premium tabs)

For the most granular control (and trailing stop alerts), apply the
**indicator** on each of the 8 chart tabs separately:

1. For each pair (EURUSD, GBPUSD, ...):
   - Open chart on H1
   - Add `indicator/wave_bot_alerts.pine`
   - Right-click → Add Alert → Condition: `WaveBot Alerts` → `Any alert() function call`
   - Set **Webhook URL** to your bot endpoint
   - Alert options: **Once per bar close**

This gives you entry + trailing update + exit alerts per pair with JSON payloads
ready for webhooks.

## 🔔 Alert JSON Payloads

All alerts emit structured JSON suitable for 3commas / custom bots / Telegram
forwarders.

### Entry
```json
{
  "bot": "myBotId",
  "action": "BUY",
  "pair": "OANDA:EURUSD",
  "entry": 1.08500,
  "sl": 1.06873,
  "tp": 1.11755,
  "size_pct": 30,
  "score": 6
}
```

### Trailing Stop Activated / Updated
```json
{ "action": "TRAIL_ON", "pair": "OANDA:EURUSD" }
{ "action": "TRAIL_UPDATE", "pair": "OANDA:EURUSD", "trail": 1.09420 }
```

### Exit
```json
{
  "action": "CLOSE_LONG",
  "pair": "OANDA:EURUSD",
  "reason": "TP",
  "exit": 1.11755
}
```

Reasons: `TP`, `SL`, `TRAIL`.

## 📐 Position Sizing Formula

```
position_size_units = (equity × 0.30) / entry_price
```

Hard-coded at 30% of equity per trade. With max 2 open = **60% max exposure**.

## ⚙️ Recommended Broker Settings

- Use OANDA, FXCM, Pepperstone, or any broker with tight spreads on majors.
- Leverage: keep modest (10-30×) - strategy already uses 30% capital per trade.
- On 3commas / your bot: set max 2 simultaneous positions globally.

## 🧪 Backtesting Checklist

Run the Strategy script on each pair with these settings:

- Date range: last 1-2 years
- Bar replay on H1
- Verify: **Win rate > 62%**, **Profit Factor > 1.8**, **Max Drawdown < 15%**

If a pair underperforms, either remove it from the scanner or raise
`minScore` to 6 for that pair.

## 🛡️ Risk Disclaimer

This is a technical trading tool, not financial advice. Forex trading carries
substantial risk of loss. **Always paper-trade first**, then scale up only
after validating live performance matches backtest. Never risk more than you
can afford to lose.

## 📈 Other Strategies in This Repo

- **[Bollinger Harami Ichimoku](BOLLINGER_HARAMI.md)** — a 5-minute reversal
  strategy: a Harami candle printing outside a Bollinger Band, exiting at the
  Ichimoku baseline (Kijun-sen), with a dynamic swing-based stop.
  Files: `strategy/bollinger_harami_strategy.pine`,
  `indicator/bollinger_harami_indicator.pine`.

## 📂 Branch

WaveBot development on `claude/wave-trading-bot-1nXME`.
Bollinger Harami development on `claude/trading-strategy-bollinger-harami-mf82pz`.
