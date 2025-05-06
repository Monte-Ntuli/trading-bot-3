# Trading Bot 3 (Supply & Demand Zones with Risk Management)

A MetaTrader 5 (MT5) Expert Advisor that automatically detects supply and demand zones using candlestick patterns and ATR filters. The bot includes dynamic risk calculation, trailing stop functionality, and zone validation logic.

## 📈 Features

- ✅ Detects **demand** and **supply** zones using price action
- 📊 Filters zones with **ATR-based big candle detection**
- 🔄 Implements **trailing stops** with throttled updates
- 📉 Calculates risk respecting **margin requirements**
- 🧠 Supports zone **aging** and **growth over time**
- 🔍 Configurable **EMA and ATR** indicators
- 🕒 Custom **trading hours** control
- 🚨 Full **parameter validation** at initialization

## ⚙️ Parameters

| Name               | Description                                |
|--------------------|--------------------------------------------|
| `ATRPeriod`        | Period used for ATR calculations            |
| `ZoneLookback`     | Number of candles to scan for zones        |
| `ZoneBodyRatio`    | Ratio to filter big-bodied candles         |
| `RiskPercent`      | Percentage of balance to risk per trade    |
| `TrailingStop`     | Distance in points for trailing stop       |
| `ThrottleInterval` | Minimum seconds between trailing updates   |
| `TradingHours`     | Format `HH:MM-HH:MM`, e.g., `09:00-17:00`  |

> ⚠️ All parameters are validated during initialization. Invalid settings will prevent the bot from running.

## 📂 File Structure

```plaintext
trading-bot-3/
├── Supply_Demand.mq5     # Main EA file
├── Supply_Demand.ex5     # Compiled EA (optional)
├── README.md             # Project documentation
