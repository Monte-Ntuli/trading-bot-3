//+------------------------------------------------------------------+
//| Expert Advisor for Supply and Demand Trading (Merged Version)    |
//| Uses H1 timeframe, ATR-based SL/TP, unlimited trades, etc.       |
//+------------------------------------------------------------------+
#property strict
#define MAX_ZONES 100

#include <Trade\Trade.mqh>

input int    ATRPeriod           = 14;            // ATR indicator period
input double ATR_SL_Mult         = 3.0;           // ATR multiplier for Stop Loss
input double ATR_TP_Mult         = 3.0;           // ATR multiplier for Take Profit
input double RiskPercent         = 1.0;           // Risk percent per trade
input string TradingHours        = "02:00-22:00";// Trading window (HH:MM-HH:MM)
input int    EMAPeriodFast       = 50;            // Fast EMA period for trend detection
input int    EMAPeriodSlow       = 200;           // Slow EMA period for trend detection
input bool   EnableTrailing      = true;          // Enable ATR-based trailing stop
input double TrailingATR_Mult    = 1.0;           // ATR multiplier for trailing stop
input bool   UsePartialClose     = true;          // Enable partial position closing
input double PartialCloseATR_Mult = 2.0;          // ATR multiplier for partial close
input int    MaxZoneAgeDays      = 14;            // Maximum age of supply/demand zones (days)
input int    ZoneLookback         = 100;           // How many bars back to scan for zones
input double ZoneBodyRatio        = 0.7;          // Minimum body/range ratio to count as "strong"

CTrade trade; // Trading class for sending orders

// Indicator handles for ATR and EMAs
int atrHandle     = INVALID_HANDLE;
int emaFastHandle = INVALID_HANDLE;
int emaSlowHandle = INVALID_HANDLE;

// Buffers for indicator values
double atrBuffer[1];
double emaFastBuffer[1];
double emaSlowBuffer[1];

// Supply/Demand zone structure
struct Zone {
  double    top;           // Upper price of the zone
  double    bottom;        // Lower price of the zone
  int       type;          //  1 = demand zone (buy), -1 = supply zone (sell)
  datetime  time_created;  // Timestamp when the zone was created
};

Zone zones[MAX_ZONES];
int zoneCount = 0;  // Number of stored zones

//+------------------------------------------------------------------+
//| Check if current time is within the allowed trading window       |
//+------------------------------------------------------------------+
bool IsTradingHour()
{
  // Input format "HH:MM-HH:MM"
  string from = StringSubstr(TradingHours, 0, 5);
  string to   = StringSubstr(TradingHours, 6, 5);
  int fh = StringToInteger(StringSubstr(from,0,2)) * 60 + StringToInteger(StringSubstr(from,3,2));
  int th = StringToInteger(StringSubstr(to,0,2))   * 60 + StringToInteger(StringSubstr(to,3,2));
  
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMins = dt.hour * 60 + dt.min;

  if(fh < th)
    return (nowMins >= fh && nowMins <= th);
  else
    return (nowMins >= fh || nowMins <= th);
}

//+------------------------------------------------------------------+
//| Initialization                                                  |
//+------------------------------------------------------------------+
int OnInit()
{
  // Create ATR and EMA handles on H1
  atrHandle = iATR(_Symbol, PERIOD_H1, ATRPeriod);
  emaFastHandle = iMA(_Symbol, PERIOD_H1, EMAPeriodFast, 0, MODE_EMA, PRICE_CLOSE);
  emaSlowHandle = iMA(_Symbol, PERIOD_H1, EMAPeriodSlow, 0, MODE_EMA, PRICE_CLOSE);
  if(atrHandle == INVALID_HANDLE || emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE)
  {
    Print("Error creating indicator handles");
    return(INIT_FAILED);
  }
  ArraySetAsSeries(atrBuffer, true);
  ArraySetAsSeries(emaFastBuffer, true);
  ArraySetAsSeries(emaSlowBuffer, true);
  
   // Set a magic number
  trade.SetExpertMagicNumber(202503);
  
  // Start timer for periodic tasks (every 60 seconds)
  EventSetTimer(60);
  Print("✅ EA initialized.");
  return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinitialization                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
  if(atrHandle != INVALID_HANDLE)     IndicatorRelease(atrHandle);
  if(emaFastHandle != INVALID_HANDLE) IndicatorRelease(emaFastHandle);
  if(emaSlowHandle != INVALID_HANDLE) IndicatorRelease(emaSlowHandle);
  EventKillTimer();
}

//+------------------------------------------------------------------+
//| Timer event: purge old zones periodically                       |
//+------------------------------------------------------------------+
void OnTimer()
{
  PurgeZones();
}

//+------------------------------------------------------------------+
//| Main tick event                                                 |
//+------------------------------------------------------------------+
void OnTick()
{
  // Ensure processing only on H1 timeframe data
  static datetime lastBarTime = 0;
  datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);
  if(currentBarTime != lastBarTime)
  {
    lastBarTime = currentBarTime;
    // New H1 bar: check for zone formation and purge old zones
    CheckForZones();
    PurgeZones();
  }
  
  // Manage open positions (trailing stops, partial exits)
  ManagePositions();
  
  // Check for new entries if within trading hours
  if(IsTradingHour())
    CheckForEntries();
}

//+------------------------------------------------------------------+
//| Detect new supply/demand zones using engulfing candles          |
//+------------------------------------------------------------------+
void CheckForZones()
{
   if(CopyBuffer(atrHandle,0,0,1,atrBuffer)<=0) return;
   double atr = atrBuffer[0];
  int bars = iBars(_Symbol, PERIOD_H1);
  int look = MathMin(bars-2, ZoneLookback);
  
  for(int i=2; i<look; i++)
  {
    // Bar i is candidate; Bar i+1 is prior
    double o = iOpen (_Symbol, PERIOD_H1, i);
    double c = iClose(_Symbol, PERIOD_H1, i);
    double h = iHigh (_Symbol, PERIOD_H1, i);
    double l = iLow  (_Symbol, PERIOD_H1, i);
    double body  = MathAbs(c - o);
    double range = h - l;
    if(range <= atr) continue;               // require range > ATR
    if(body/range < ZoneBodyRatio) continue; // require strong body

    double o1 = iOpen (_Symbol, PERIOD_H1, i+1);
    double c1 = iClose(_Symbol, PERIOD_H1, i+1);
    // bullish after bearish → demand zone
    if(c1 < o1 && c > o && c > o1 && o < c1)
    {
      if(zoneCount < MAX_ZONES)
      {
        Zone z;
        z.top          = h;
        z.bottom       = l;
        z.type         = 1;
        z.time_created = TimeCurrent();
        zones[zoneCount++] = z;
      }
    }
    // bearish after bullish → supply zone
    if(c1 > o1 && c < o && c < o1 && o > c1)
    {
      if(zoneCount < MAX_ZONES)
      {
        Zone z;
        z.top          = h;
        z.bottom       = l;
        z.type         = -1;
        z.time_created = TimeCurrent();
        zones[zoneCount++] = z;
      }
    }
  }
  
  //
  if(iBars(_Symbol, PERIOD_H1) < 3) return;
  // Use the last two completed bars: index 2 = older, index 1 = recent
  double open2  = iOpen(_Symbol, PERIOD_H1, 2);
  double close2 = iClose(_Symbol, PERIOD_H1, 2);
  double low2   = iLow(_Symbol, PERIOD_H1, 2);
  double high2  = iHigh(_Symbol, PERIOD_H1, 2);
  
  double open1  = iOpen(_Symbol, PERIOD_H1, 1);
  double close1 = iClose(_Symbol, PERIOD_H1, 1);
  double low1   = iLow(_Symbol, PERIOD_H1, 1);
  double high1  = iHigh(_Symbol, PERIOD_H1, 1);

  // Bullish engulfing? (reversal to uptrend)
  bool bullishEngulf = (close2 < open2) && (close1 > open1) && (close1 > open2) && (open1 < close2);
  if(bullishEngulf)
  {
    Zone z;
    z.type = 1; // Demand zone
    z.top = high2;
    z.bottom = MathMin(low2, low1);
    z.time_created = TimeCurrent();
    if(zoneCount < ArraySize(zones))
      zones[zoneCount++] = z;
  }
  // Bearish engulfing? (reversal to downtrend)
  bool bearishEngulf = (close2 > open2) && (close1 < open1) && (close1 < open2) && (open1 > close2);
  if(bearishEngulf)
  {
    Zone z;
    z.type = -1; // Supply zone
    z.top = MathMax(high2, high1);
    z.bottom = low2;
    z.time_created = TimeCurrent();
    if(zoneCount < ArraySize(zones))
      zones[zoneCount++] = z;
  }
}

//+------------------------------------------------------------------+
//| Remove zones that are too old or invalidated by price action     |
//+------------------------------------------------------------------+
void PurgeZones()
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   for(int i=zoneCount-1; i>=0; i--)
  {
    bool remove = false;
    Zone z = zones[i];
    if(TimeCurrent() - z.time_created > MaxZoneAgeDays*86400) remove = true;
    double extra = (z.top - z.bottom)*0.1;
    if(z.type==1 && (price > z.top+extra || price < z.bottom-extra)) remove = true;
    if(z.type==-1&& (price < z.bottom-extra|| price > z.top+extra)) remove = true;
    if(remove)
    {
      for(int j=i; j<zoneCount-1; j++) zones[j]=zones[j+1];
      zoneCount--;
    }
  }
  
  for(int i = zoneCount-1; i >= 0; i--)
  {
    bool remove = false;
    Zone z = zones[i];
    // Age-based removal
    if(TimeCurrent() - z.time_created > MaxZoneAgeDays * 86400)
      remove = true;
    double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    // Demand zone conditions to remove
    if(z.type == 1)
    {
      if(currentPrice > z.top + (z.top - z.bottom)*0.1)    // zone broken on upside
        remove = true;
      if(currentPrice < z.bottom - (z.top - z.bottom)*0.1) // price fell well below
        remove = true;
    }
    // Supply zone conditions to remove
    if(z.type == -1)
    {
      if(currentPrice < z.bottom - (z.top - z.bottom)*0.1)
        remove = true;
      if(currentPrice > z.top + (z.top - z.bottom)*0.1)
        remove = true;
    }
    if(remove)
    {
      // Shift array to delete zone
      for(int j=i; j<zoneCount-1; j++)
        zones[j] = zones[j+1];
      zoneCount--;
    }
  }
}

//+------------------------------------------------------------------+
//| Manage open positions: trailing stop and partial close           |
//+------------------------------------------------------------------+
void ManagePositions()
{
  // Get current ATR value
  if(CopyBuffer(atrHandle, 0, 0, 1, atrBuffer) <= 0) return;
  double atr = atrBuffer[0];

  // Iterate through all positions on current symbol
  if (PositionSelect(_Symbol))
   {  
      ulong   ticket   = PositionGetInteger(POSITION_TICKET);
    double  openP    = PositionGetDouble(POSITION_PRICE_OPEN);
    double  curSL    = PositionGetDouble(POSITION_SL);
    double  profit   = PositionGetDouble(POSITION_PROFIT);
    int     type     = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
    double  volume   = PositionGetDouble(POSITION_VOLUME);
    
    // ATR Trailing Stop
    if(EnableTrailing && atr>0 && profit>0)
  {
    double newSL = (type==1) ? openP + atr*TrailingATR_Mult
                              : openP - atr*TrailingATR_Mult;
    if((type==1 && newSL>curSL) || (type==-1 && newSL<curSL))
      trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
  }
    
    // Partial Close at profit target
    if(UsePartialClose && atr > 0 && profit >= atr * PartialCloseATR_Mult)
    {
      double halfVol = volume / 2.0;
      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      halfVol = MathFloor(halfVol / lotStep) * lotStep;
      if(halfVol > 0.0)
        trade.PositionClosePartial(ticket, halfVol);
    }
    
   }
}

//+------------------------------------------------------------------+
//| Evaluate zones and open trades when conditions are met           |
//+------------------------------------------------------------------+
void CheckForEntries()
{
  // Get latest indicator values
  if(CopyBuffer(emaFastHandle, 0, 0, 1, emaFastBuffer) <= 0) return;
  if(CopyBuffer(emaSlowHandle, 0, 0, 1, emaSlowBuffer) <= 0) return;
  if(CopyBuffer(atrHandle, 0, 0, 1, atrBuffer) <= 0) return;
  double emaFast = emaFastBuffer[0];
  double emaSlow = emaSlowBuffer[0];
  double atr     = atrBuffer[0];

  // Last completed H1 bar (index 1)
  double open1  = iOpen(_Symbol, PERIOD_H1, 1);
  double high1  = iHigh(_Symbol, PERIOD_H1, 1);
  double low1   = iLow(_Symbol, PERIOD_H1, 1);
  double close1 = iClose(_Symbol, PERIOD_H1, 1);

  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  
  // loop zones
  for(int i=0; i<zoneCount; i++)
  {
    Zone z = zones[i];
    // demand
    if(z.type==1 && low1<=z.bottom && close1>open1 && emaFast>emaSlow)
    {
      double entry = ask;
      double sl    = entry - atr*ATR_SL_Mult;
      double tp    = entry + atr*ATR_TP_Mult;
      if(TryPlaceOrder(ORDER_TYPE_BUY, entry, sl, tp))
      {
        // remove zone
        ArrayRemove(zones, i, zoneCount);
        zoneCount--;
        i--;
      }
    }
    // supply
    if(z.type==-1&& high1>=z.top   && close1<open1 && emaFast<emaSlow)
    {
      double entry = bid;
      double sl    = entry + atr*ATR_SL_Mult;
      double tp    = entry - atr*ATR_TP_Mult;
      if(TryPlaceOrder(ORDER_TYPE_SELL, entry, sl, tp))
      {
        ArrayRemove(zones, i, zoneCount);
        zoneCount--;
        i--;
      }
    }
   }
  // Loop through supply/demand zones for potential entries
  for(int i = 0; i < zoneCount; i++)
  {
    Zone z = zones[i];

    // -------- Demand Zone (Buy) --------
    if(z.type == 1)
    {
      // Price entered zone and last bar was bullish
      if(low1 <= z.bottom && close1 > open1)
      {
        // Check market regime: only buy if uptrend
        if(emaFast <= emaSlow) continue;

        double entryPrice = ask;
        double stopPrice  = entryPrice - atr * ATR_SL_Mult;
        double tpPrice    = entryPrice + atr * ATR_TP_Mult;

        // Calculate lot size based on risk
        double riskAmt = AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPercent / 100.0);
        double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double slDist   = MathAbs(entryPrice - stopPrice);
        double volume   = 0.0;
        if(slDist > 0 && tickVal > 0)
          volume = riskAmt / (slDist * tickVal);

        // Adjust volume to nearest allowed step
        double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
        double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
        if(volume > 0)
        {
          volume = MathFloor(volume / lotStep) * lotStep;
          if(volume < minLot) volume = minLot;
        }

        if(volume > 0)
        {
          trade.SetTypeFilling(ORDER_FILLING_IOC);
          if(trade.Buy(volume, _Symbol, entryPrice, stopPrice, tpPrice, "DemandZone"))
          {
            // Remove the zone after a trade
            for(int j=i; j<zoneCount-1; j++) zones[j] = zones[j+1];
            zoneCount--;
            i--; // adjust index
          }
          else
          {
            Print("Buy failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
          }
        }
      }
    }

    // -------- Supply Zone (Sell) --------
    else if(z.type == -1)
    {
      if(high1 >= z.top && close1 < open1)
      {
        // Only sell if downtrend
        if(emaFast >= emaSlow) continue;

        double entryPrice = bid;
        double stopPrice  = entryPrice + atr * ATR_SL_Mult;
        double tpPrice    = entryPrice - atr * ATR_TP_Mult;

                double riskAmt  = AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPercent / 100.0);
        double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double slDist   = MathAbs(stopPrice - entryPrice);
        double volume   = 0.0;

        if(slDist > 0 && tickVal > 0)
          volume = riskAmt / (slDist * tickVal);

        // Adjust volume to nearest allowed step
        double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
        double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
        if(volume > 0)
        {
          volume = MathFloor(volume / lotStep) * lotStep;
          if(volume < minLot) volume = minLot;
        }

        if(volume > 0)
        {
          trade.SetTypeFilling(ORDER_FILLING_IOC);
          if(trade.Sell(volume, _Symbol, entryPrice, stopPrice, tpPrice, "SupplyZone"))
          {
            // Remove the zone after successful trade
            for(int j=i; j<zoneCount-1; j++) zones[j] = zones[j+1];
            zoneCount--;
            i--; // adjust index
          }
          else
          {
            Print("Sell failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
          }
        }
      }
    }
  }
}

//+------------------------------------------------------------------+
//| Helper: place market order with risk-based volume               |
//+------------------------------------------------------------------+
bool TryPlaceOrder(ENUM_ORDER_TYPE type, double price, double sl, double tp)
{
  // 1) Basic risk‐based volume calculation
  double balance = AccountInfoDouble(ACCOUNT_BALANCE);
  double riskAmt = balance * (RiskPercent/100.0);
  double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
  double dist    = MathAbs(price - sl);
  if(dist <= 0 || tickVal <= 0)
    return(false);

  double vol = riskAmt / (dist*tickVal);
  // 2) Enforce min/max/step
  double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  vol = MathFloor(vol/step) * step;
  vol = MathMax(minL, MathMin(vol, maxL));
  if(vol < minL)
    return(false);
    
  
  // 3) Compute margin required and compare to free margin
  double marginRequired = 0.0;
  if(!OrderCalcMargin(type, _Symbol, vol, price, marginRequired))
  {
    Print(__FUNCTION__,": OrderCalcMargin failed, err=", GetLastError());
    return(false);
  }
  double freeM = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
  if(marginRequired > freeM)
  {
    Print(__FUNCTION__,": insufficient free margin. Need=", marginRequired,
          " Free=", freeM);
    return(false);
  }
  
  
  // 4) Send the order
  trade.SetTypeFilling(ORDER_FILLING_IOC);
  bool ok = (type == ORDER_TYPE_BUY)
            ? trade.Buy (vol, _Symbol, price, sl, tp, "ZoneEntry")
            : trade.Sell(vol, _Symbol, price, sl, tp, "ZoneEntry");
  if(!ok)
    Print(__FUNCTION__,": Order failed code=", trade.ResultRetcode(),
          " desc=", trade.ResultRetcodeDescription());
  return(ok);
}
