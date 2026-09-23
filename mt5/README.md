# Range Re-entry EA (MetaTrader 5)

`RangeReentry_EA.mq5` is an Expert Advisor for MT5. It trades range breakouts
that fail and come back inside the range (a liquidity sweep). It trades four
assets on M5 entries and includes guards for FTMO rules.

## Strategy

| Asset | Range window (Israel time) | Active window (next 20 h) |
|-------|----------------------------|---------------------------|
| EURUSD | 03:00 - 07:00 | 07:00 - 03:00 |
| XAUUSD | 04:00 - 08:00 | 08:00 - 04:00 |
| US100  | 12:00 - 16:00 | 16:00 - 12:00 |
| US500  | 12:00 - 16:00 | 16:00 - 12:00 |

* **Range:** the highest high and lowest low of all M5 bars in the 4-hour
  window. No trades are opened during the window.
* **SELL:** some earlier bar (N-1 or before) closed **above** the range high,
  then bar N closes back **at or below** the range high. The EA sends a market
  sell at the open of bar N+1.
* **BUY:** the mirror case. Some earlier bar closed **below** the range low,
  then bar N closes back **at or above** the range low.
* **SL** = 1.5 × (High[N] − Low[N]). **TP** = 2 × the SL distance, so the
  reward:risk is 1:2.
* **Max 1 open position on the whole account.** No entry is made unless
  `PositionsTotal() == 0`.
* After a trade is taken, the breakout flag resets. The next trade in the same
  session needs a new close outside the range.

## Protection (FTMO)

| Guard | Behaviour |
|-------|-----------|
| IsNewBar | Bar logic runs **once** per new M5 bar of each symbol, not on every tick. |
| Spread filter | No entry while the spread is above `Max_Spread_Pips`. The EA keeps checking for `InpEntryRetrySeconds` and then skips the signal. |
| Friday close-out | At **Friday 22:30 Israel time** it closes positions. No new entries until Monday. |
| Daily loss kill-switch | If equity drops `Daily_Loss_Limit_Percent` below the day's starting reference (realized + floating), it closes everything and stops trading until the next daily reset. This state survives a terminal restart. |
| Risk sizing | Lot size is set so that hitting the SL loses `Risk_Percent_Per_Trade` of the balance. The EA always rounds down and checks margin. |

## Installation (desktop / VPS)

1. MT5 → **File → Open Data Folder** → `MQL5/Experts/` → copy `RangeReentry_EA.mq5` there.
2. Open it in **MetaEditor** (F4) → **Compile** (F7).
3. Open **one** chart (any symbol, any timeframe) and drag the EA onto it.
   The EA trades all four symbols from that one chart. **Do not attach it to
   more than one chart.**
4. In the **Common** tab, tick *Allow Algo Trading*. Turn on the **Algo Trading** button in the toolbar.
5. Check that the symbol names match your broker's Market Watch exactly.
   The defaults are FTMO-style (`US100.cash`, `US500.cash`). Other brokers use
   names like `NAS100`, `USTEC`, `SPX500` or `US500`.

## Mobile

The MT5 mobile app **cannot run Expert Advisors**. The EA has to run on the
desktop terminal (Windows) or on a VPS, for example the built-in MetaQuotes
VPS, so it keeps trading when your PC is off. The phone is then used to
monitor it:

* Every trade, SL/TP hit, Friday close-out and kill-switch event is sent as a
  **push notification** to the MT5 mobile app.
* To enable it: mobile app → *Settings → Messages* → copy your **MetaQuotes ID**.
  Desktop → *Tools → Options → Notifications* → enable and paste the ID.
* The positions opened by the EA also show in the mobile app's *Trade* tab.

## Time alignment (important)

MT5 uses the broker's **server** time. The strategy is defined in
**Israel** time. The EA converts between them.

* **Auto mode (default):** set the server's winter GMT offset (usually `2`)
  and its DST schedule (usually `US`). The EA then applies the US/EU and
  Israeli DST rules, so it stays aligned all year, including in backtests.
* **Manual mode:** a fixed `Israel time − server time` in hours.

When the EA starts on a live chart, it compares its Israel time with the PC
clock and **warns you** if they don't match. Check the *Experts* tab after
you attach it.

## Strategy Tester

* Attach it to any of the four symbols on M5. The tester loads the other
  three automatically.
* Modelling: **Every tick based on real ticks** gives accurate spreads.
  **1 minute OHLC** is faster.
* All requested parameters are exposed: time offset, `Max_Spread_Pips` (one per
  asset), `Risk_Percent_Per_Trade`, `Daily_Loss_Limit_Percent`.

## Key inputs

| Input | Default | Notes |
|-------|---------|-------|
| `Max_Spread_Pips` (per asset) | 1.5 / 5.0 / 3.0 / 1.0 | Pip size per asset: EURUSD 0.0001, XAUUSD 0.10, indices 1 point. |
| `Risk_Percent_Per_Trade` | 1.0 | % of balance lost if the SL is hit. |
| `Daily_Loss_Limit_Percent` | 3.0 | Base is the day-start balance/equity. You can set a fixed amount instead (e.g. `100000` to match FTMO's "% of initial balance"). |
| Daily reset hour (server) | 0 | Set this to your prop firm's daily reset time. |
| Guards close ALL positions | true | FTMO rules apply to the whole account. Set to `false` to touch only this EA's trades. |
| Keep breakout flag when skipped | true | Follows the spec literally: the flag resets only after a trade is **taken**. If a signal is blocked (e.g. another asset has a position open), a later close back inside can still trigger. Set to `false` to require a fresh breakout after any missed signal. |
| Entry retry seconds | 30 | How long to keep trying at the open of bar N+1 (wide spread, requote, reconnect). `0` = one attempt. |
| Min range bars | 30 | Minimum M5 bars in the 4-hour window (48 max). Below this, the session isn't traded, for example on a holiday or the first session after the weekend. |

## Notes

* Only one position at a time on the account: if two assets signal on the same
  bar, the one listed first in the inputs is traded.
* When the EA restarts mid-session, it rebuilds the range and breakout flags
  from history without trading. It then continues from the next M5 bar.
* The daily loss check is equity-based. Deposits or withdrawals during the day
  distort it.
* Commission is not included in the lot-size risk calculation.

## Risk Disclaimer

This is a trading tool, not financial advice. Backtest and demo-trade first.
