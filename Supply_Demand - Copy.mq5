//+------------------------------------------------------------------+
//| Expert Advisor for Supply and Demand Trading (Enhanced Version)   |
//| Implements throttled trailing stops, buffer series orientation,   |
//| and zone array bounds safety.                                    |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

#define MAX_ZONES 100

//--- Inputs
input int    ATRPeriod            = 14;
input double ATR_SL_Mult          = 3.0;
input double ATR_TP_Mult          = 3.0;
input double RiskPercent          = 1.0;
input string TradingHours         = "02:00-22:00";
input int    EMAPeriodFast        = 50;
input int    EMAPeriodSlow        = 200;
input bool   EnableTrailing       = true;
input double TrailingATR_Mult     = 1.0;
input bool   UsePartialClose      = true;
input double PartialCloseATR_Mult = 2.0;
input int    MaxZoneAgeDays       = 14;
input int    ZoneLookback         = 50;
input double ZoneBodyRatio        = 0.7;

//--- Trade object
CTrade trade;

//--- Indicator handles & buffers
int   atrHandle, emaFastHandle, emaSlowHandle;
double atrBuffer[1], emaFastBuffer[1], emaSlowBuffer[1];

//--- Zone structure
struct Zone {
  double    top;
  double    bottom;
  int       type;         // 1 = demand, -1 = supply
  datetime  time_created; // bar timestamp
};
Zone  zones[MAX_ZONES];
int   zoneCount = 0;

//+------------------------------------------------------------------+
//| Helper: safely add a zone                                        |
//+------------------------------------------------------------------+
void AddZone(double top,double bottom,int type,datetime barTime)
{
  if(zoneCount >= MAX_ZONES)
  {
    Print(__FUNCTION__, ": zone array full (", zoneCount, "), skipping.");
    return;
  }
  zones[zoneCount].top          = top;
  zones[zoneCount].bottom       = bottom;
  zones[zoneCount].type         = type;
  zones[zoneCount].time_created = barTime;
  zoneCount++;
}

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
  //--- Parameter validation
  // ATR period must be positive
  if(ATRPeriod <= 0)
  {
    Print(__FUNCTION__, ": invalid ATRPeriod (<=0)");
    return(INIT_FAILED);
  }
  // EMA periods must be positive
  if(EMAPeriodFast <= 0 || EMAPeriodSlow <= 0)
  {
    Print(__FUNCTION__, ": invalid EMA period(s)");
    return(INIT_FAILED);
  }
  // Zone lookback must be at least 3 bars
  if(ZoneLookback < 3)
  {
    Print(__FUNCTION__, ": ZoneLookback must be >= 3");
    return(INIT_FAILED);
  }
  // Zone body ratio between 0 and 1
  if(ZoneBodyRatio <= 0.0 || ZoneBodyRatio > 1.0)
  {
    Print(__FUNCTION__, ": ZoneBodyRatio must be between 0 and 1");
    return(INIT_FAILED);
  }
  // TradingHours format HH:MM-HH:MM
  if(StringLen(TradingHours) != 11 || TradingHours[2] != ':' || TradingHours[5] != '-' || TradingHours[8] != ':')
  {
    Print(__FUNCTION__, ": TradingHours format invalid, expected HH:MM-HH:MM");
    return(INIT_FAILED);
  }
  {
    string from = StringSubstr(TradingHours, 0, 5);
    string to   = StringSubstr(TradingHours, 6, 5);
    int fh = StringToInteger(StringSubstr(from, 0, 2));
    int fm = StringToInteger(StringSubstr(from, 3, 2));
    int th = StringToInteger(StringSubstr(to,   0, 2));
    int tm = StringToInteger(StringSubstr(to,   3, 2));
    if(fh < 0 || fh > 23 || th < 0 || th > 23 || fm < 0 || fm > 59 || tm < 0 || tm > 59)
    {
      Print(__FUNCTION__, ": TradingHours values out of range");
      return(INIT_FAILED);
    }
  }

  // create ATR and EMA handles
  atrHandle     = iATR(_Symbol, PERIOD_H1, ATRPeriod);
  emaFastHandle = iMA (_Symbol, PERIOD_H1, EMAPeriodFast, 0, MODE_EMA, PRICE_CLOSE);
  emaSlowHandle = iMA (_Symbol, PERIOD_H1, EMAPeriodSlow, 0, MODE_EMA, PRICE_CLOSE);
  if(atrHandle==INVALID_HANDLE || emaFastHandle==INVALID_HANDLE || emaSlowHandle==INVALID_HANDLE)
    return(INIT_FAILED);

  // ensure buffers are series-oriented for multi-bar fetches
  ArraySetAsSeries(atrBuffer,    true);
  ArraySetAsSeries(emaFastBuffer,true);
  ArraySetAsSeries(emaSlowBuffer,true);

  trade.SetExpertMagicNumber(202503);
  EventSetTimer(60);
  return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
  if(atrHandle!=INVALID_HANDLE)     IndicatorRelease(atrHandle);
  if(emaFastHandle!=INVALID_HANDLE) IndicatorRelease(emaFastHandle);
  if(emaSlowHandle!=INVALID_HANDLE) IndicatorRelease(emaSlowHandle);
  EventKillTimer();
}

//+------------------------------------------------------------------+
//| Timer: purge old zones                                           |
//+------------------------------------------------------------------+
void OnTimer() { PurgeZones(); }

//+------------------------------------------------------------------+
//| Main tick handler                                               |
//+------------------------------------------------------------------+
void OnTick()
{
  static datetime lastBar = 0;
  datetime curBar = iTime(_Symbol, PERIOD_H1, 0);
  if(curBar != lastBar)
  {
    lastBar = curBar;
    ScanForZones();
    PurgeZones();
  }

  ManagePositions();
  if(IsTradingHour())
    CheckForEntries();
}

//+------------------------------------------------------------------+
//| Scan past bars for strong supply/demand zones                    |
//+------------------------------------------------------------------+
void ScanForZones()
{
  if(CopyBuffer(atrHandle,0,0,1,atrBuffer)<=0) return;
  double atr = atrBuffer[0];
  int bars = iBars(_Symbol, PERIOD_H1);
  int look = MathMin(bars-2, ZoneLookback);

  for(int i=2; i<look; i++)
  {
    datetime barTime = iTime(_Symbol, PERIOD_H1, i);
    // skip if zone exists for this bar
    bool exists = false;
    for(int j=0;j<zoneCount;j++) if(zones[j].time_created==barTime){exists=true;break;}
    if(exists) continue;

    double o = iOpen (_Symbol, PERIOD_H1, i);
    double c = iClose(_Symbol, PERIOD_H1, i);
    double h = iHigh (_Symbol, PERIOD_H1, i);
    double l = iLow  (_Symbol, PERIOD_H1, i);
    double body = MathAbs(c-o);
    double range= h-l;
    if(range <= atr || body/range < ZoneBodyRatio) continue;

    double o1 = iOpen (_Symbol, PERIOD_H1, i+1);
    double c1 = iClose(_Symbol, PERIOD_H1, i+1);
    // demand zone
    if(c1<o1 && c>o && c>o1 && o<c1)
      AddZone(h,l,1,barTime);
    // supply zone
    else if(c1>o1 && c<o && c<o1 && o>c1)
      AddZone(h,l,-1,barTime);
  }
}

//+------------------------------------------------------------------+
//| Purge zones by age or break                                      |
//+------------------------------------------------------------------+
void PurgeZones()
{
  double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  for(int i=zoneCount-1; i>=0; i--)
  {
    Zone z = zones[i]; bool remove=false;
    if(TimeCurrent()-z.time_created > MaxZoneAgeDays*86400) remove=true;
    double extra=(z.top-z.bottom)*0.1;
    if(z.type==1 && (price>z.top+extra||price<z.bottom-extra)) remove=true;
    if(z.type==-1&& (price<z.bottom-extra||price>z.top+extra)) remove=true;
    if(remove)
    {
      for(int j=i;j<zoneCount-1;j++) zones[j]=zones[j+1];
      zoneCount--;
    }
  }
}

//+------------------------------------------------------------------+
//| Manage positions: throttled trailing stops and partial closes    |
//+------------------------------------------------------------------+
void ManagePositions()
{
  if(!PositionSelect(_Symbol)) return;
  static datetime lastTrailBar = 0;
  // get ATR and current bar time
  if(CopyBuffer(atrHandle,0,0,1,atrBuffer)<=0) return;
  double atr = atrBuffer[0];
  datetime barTime = iTime(_Symbol, PERIOD_H1, 0);

  ulong  ticket = PositionGetInteger(POSITION_TICKET);
  double openP  = PositionGetDouble(POSITION_PRICE_OPEN);
  double curSL  = PositionGetDouble(POSITION_SL);
  double profit = PositionGetDouble(POSITION_PROFIT);
  int    type   = PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? 1 : -1;
  double vol    = PositionGetDouble(POSITION_VOLUME);

  // throttle trailing: only once per new bar and if improvement >= one point
  if(EnableTrailing && profit>0 && barTime!=lastTrailBar)
  {
    double newSL = type==1 ? openP+atr*TrailingATR_Mult : openP-atr*TrailingATR_Mult;
    if((type==1 && newSL>curSL+_Point) || (type==-1 && newSL<curSL-_Point))
    {
      trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
      lastTrailBar = barTime;
    }
  }

  // partial close
  if(UsePartialClose && profit>=atr*PartialCloseATR_Mult)
  {
    double half = MathFloor((vol/2.0)/SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP))
                  *SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
    if(half>0) trade.PositionClosePartial(ticket, half);
  }
}

//+------------------------------------------------------------------+
//| Entry logic based on zones, ATR, and EMA regime                 |
//+------------------------------------------------------------------+
bool TryPlaceOrder(ENUM_ORDER_TYPE type,double price,double sl,double tp)
{
  double bal    = AccountInfoDouble(ACCOUNT_BALANCE);
  double riskAmt= bal*(RiskPercent/100);
  double tickVal= SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
  double dist   = MathAbs(price-sl);
  if(dist<=0||tickVal<=0) return false;

  double vol = riskAmt/(dist*tickVal);
  double minL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),
         maxL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),
         step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
  vol = MathFloor(vol/step)*step;
  vol = MathMax(minL, MathMin(vol, maxL));
  if(vol<minL) return false;

  double mreq;
  if(!OrderCalcMargin(type,_Symbol,vol,price,mreq)) return false;
  if(mreq>AccountInfoDouble(ACCOUNT_MARGIN_FREE)) return false;

  trade.SetTypeFilling(ORDER_FILLING_IOC);
  bool ok = type==ORDER_TYPE_BUY
            ? trade.Buy (vol,_Symbol,price,sl,tp,"ZoneEntry")
            : trade.Sell(vol,_Symbol,price,sl,tp,"ZoneEntry");
  if(!ok) Print(__FUNCTION__,": order failed code=",trade.ResultRetcode());
  return ok;
}

void CheckForEntries()
{
  if(CopyBuffer(emaFastHandle,0,0,1,emaFastBuffer)<=0) return;
  if(CopyBuffer(emaSlowHandle,0,0,1,emaSlowBuffer)<=0) return;
  if(CopyBuffer(atrHandle,    0,0,1,atrBuffer)    <=0) return;

  double emaF=emaFastBuffer[0], emaS=emaSlowBuffer[0], atr=atrBuffer[0];
  double o1=iOpen (_Symbol,PERIOD_H1,1), c1=iClose(_Symbol,PERIOD_H1,1);
  double h1=iHigh (_Symbol,PERIOD_H1,1), l1=iLow  (_Symbol,PERIOD_H1,1);
  double ask=SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  double bid=SymbolInfoDouble(_Symbol, SYMBOL_BID);

  for(int i=0;i<zoneCount;i++)
  {
    Zone z = zones[i];
    if(z.type==1 && l1<=z.bottom && c1>o1 && emaF>emaS)
    {
      double entry=ask, sl=entry-atr*ATR_SL_Mult, tp=entry+atr*ATR_TP_Mult;
      if(TryPlaceOrder(ORDER_TYPE_BUY,entry,sl,tp))
      {
        for(int j=i;j<zoneCount-1;j++) zones[j]=zones[j+1];
        zoneCount--; i--; }
    }
    else if(z.type==-1 && h1>=z.top && c1<o1 && emaF<emaS)
    {
      double entry=bid, sl=entry+atr*ATR_SL_Mult, tp=entry-atr*ATR_TP_Mult;
      if(TryPlaceOrder(ORDER_TYPE_SELL,entry,sl,tp))
      {
        for(int j=i;j<zoneCount-1;j++) zones[j]=zones[j+1];
        zoneCount--; i--; }
    }
  }
}

bool IsTradingHour()
{
  string f=StringSubstr(TradingHours,0,5), t=StringSubstr(TradingHours,6,5);
  int fh=StringToInteger(StringSubstr(f,0,2))*60 + StringToInteger(StringSubstr(f,3,2));
  int th=StringToInteger(StringSubstr(t,0,2))*60 + StringToInteger(StringSubstr(t,3,2));
  MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
  int now=dt.hour*60 + dt.min;
  return fh<th ? (now>=fh && now<=th) : (now>=fh || now<=th);
}

//+------------------------------------------------------------------+
