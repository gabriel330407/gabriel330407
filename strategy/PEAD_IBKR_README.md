# 📈 PEAD-IBKR — Post-Earnings Announcement Drift Strategy

A fully automated **Pine Script v5** `strategy()` that harvests the **Post-Earnings
Announcement Drift (PEAD)** anomaly and ships orders to **Interactive Brokers**
via webhook JSON payloads.

> File: [`strategy/pead_ibkr_strategy.pine`](./pead_ibkr_strategy.pine)

---

## 🧠 Strategy Logic (Long-Only)

| Step | Rule |
|------|------|
| **Trigger** | An earnings report prints on the chart (reaction day). |
| **Filter 1 — Fundamental** | Reported EPS **>** Consensus EPS (beat ≥ *Min EPS Surprise %*). |
| **Filter 2 — Price** | `Close > Close[1]` on the reaction day (concordant move). |
| **Entry** | Market **BUY** at the **OPEN of the next session**. |
| **Exit** | Pure **time-based**: hold exactly *N* trading days (default **60**), then close at the open. **No SL/TP** during the hold. |

Earnings data comes from `request.earnings()` (`earnings.actual` vs
`earnings.estimate`). It only returns values on real equities with earnings
history — **use a Daily chart on a US stock** (e.g. `NASDAQ:AAPL`).

---

## ⚙️ Inputs

| Group | Input | Default | Purpose |
|-------|-------|---------|---------|
| Account | IBKR Account ID | `DU0000000` | Injected into webhook JSON |
| Account | Account Capital ($) | `100,000` | Drives position sizing |
| Account | Capital per Trade (%) | `10%` | Fixed fraction per position |
| Signal | Min EPS Surprise (%) | `0%` | Minimum beat over consensus |
| Signal | Hold Period (days) | `60` | Trading-day holding window |
| Risk | Commission / Order ($) | `2.5` | Flat per-order fee |
| Risk | Max Friction / Position (%) | `0.5%` | Skip trade if round-trip fee drag exceeds this |
| Risk | Max Portfolio Drawdown (%) | `15%` | Halt new entries below equity peak |

> Keep **Account Capital** and **Commission / Order** in sync with the
> `strategy()` header (`initial_capital` / `commission_value`) so the backtest
> equity curve matches live sizing — those header args must be constants in Pine.

---

## 🛡️ Risk Modules

- **Position sizing** — `shares = floor(capital × pct% / price)`.
- **Commission friction filter** — round-trip cost is `2 × commission`. If that
  exceeds *Max Friction / Position %* of the position value (or the size rounds
  to 0 shares), the trade is **skipped** to avoid fee drag on tiny positions.
- **Max drawdown protection** — tracks peak equity; once equity sits more than
  *Max Portfolio Drawdown %* below the peak, **all new entries halt** (open
  positions still exit on schedule). The chart background turns red when active.

---

## 🔔 Webhook JSON (→ IBKR via TradingConnector / Alertatron / Capitalise.ai)

Every order embeds an `alert_message`. Quantity is computed dynamically from
capital allocation and share price.

**Entry**
```json
{ "account": "DU0000000", "action": "BUY",  "symbol": "AAPL", "orderType": "MARKET", "quantity": 23 }
```

**Exit**
```json
{ "account": "DU0000000", "action": "SELL", "symbol": "AAPL", "orderType": "MARKET", "quantity": 23 }
```

---

## 🚀 Setup

1. TradingView → open a **Daily** chart on a US equity (e.g. `NASDAQ:AAPL`).
2. Pine Editor → paste `strategy/pead_ibkr_strategy.pine` → **Save** → **Add to Chart**.
3. Tune inputs; review **Strategy Tester** results.
4. Right-click chart → **Add Alert** → Condition: *PEAD-IBKR* →
   **Order fills only** (or *Any alert() function call*).
5. Paste your bridge **Webhook URL**, set **Once per bar close**, create.

---

## ⚠️ Disclaimer

Educational tool, **not financial advice**. Earnings-driven trades carry gap
risk. **Paper-trade on IBKR first** and validate that live fills match the
backtest before risking real capital.
