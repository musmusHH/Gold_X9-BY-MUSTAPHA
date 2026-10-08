//+------------------------------------------------------------------+
//|                                                Gold_X9_V6.3.mq5  |
//|                                  Copyright 2026, AIT CHIKH MUSTAPHA |
//|                                                                  |
//+------------------------------------------------------------------+
// GOLD X9 V6.3 - 9-strategy fractal breakout Expert Advisor for XAUUSD.
//
// Built from two files in this repository:
//   * GOOOOLD X9 SETINGS.txt               -> input names and default values
//   * gold-ea-strategy-specification-v2.pdf -> trading logic and 9-strategy matrix
//
// Core rules (from the specification):
//   - No martingale, no grid, no averaging. Every order carries a stop loss.
//   - Every distance is a percentage of price (SL, TP, entry offset, trailing,
//     break-even, salvage).
//   - Swing high/low fractals are detected on each sub-strategy's own timeframe.
//   - Sub-strategy i uses magic number InpMagic + i (i = 0..8).
//   - Small-account mode (default on): trades the minimum lot and tightens the SL so a loss
//     equals SmallRiskPct of balance. Entries, TP and trailing/BE rules are unchanged.
//   - Prop-firm guards: daily equity stop, max peak-to-trough equity stop,
//     pending order expiry, and optional micro-offset randomizer.
//+------------------------------------------------------------------+
#property copyright "AIT CHIKH MUSTAPHA"
#property link      "https://www.mql5.com"
#property version   "6.30"
#property strict
#property description "GOLD X9 V6.3 - 9 parallel fractal breakout sub-strategies for XAUUSD."
#property description "Inputs from 'GOOOOLD X9 SETINGS.txt'; logic from the v2 strategy specification."

#include <Trade\Trade.mqh>

#define STRATEGY_COUNT 9
const double MAX_LOT_CAP = 100.0;   // hard upper limit on lots per order (from draft code)

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_LOT_METHOD
  {
   LOT_FIXED    = 0, // Fixed Lots
   LOT_TIERED   = 1, // Tiered Lot Sizing
   LOT_RISK_PCT = 2  // Risk Scaling Factor (%)
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group " === TRADE SETUP === "
input int      InpMagic       = 647873;                          // EA Magic Number (sub-strategy i uses Magic + i)
input string   TradeComment   = "Gold X9 by AIT CHIKHMUSTAPHA";  // Comment for trades
input int      InpSlippage    = 30;                              // Max slippage (points)

input group "=== MONEY MANAGEMENT / Lotsize Calculations === "
input ENUM_LOT_METHOD Lotsizing_Method  = LOT_FIXED;    // Lotsize calculation method (LOT_FIXED = MQ4 behaviour)
input double   TieredLot          = 30;      // Tiered Lot Sizing Risk Meter (1 - 100)
input double   TieredMaxRiskPct   = 5.0;     // Risk % of balance per trade at meter 100 (Tiered only)
input double   FixedLots          = 0.01;    // Fixed Lots
input double   RiskScaling        = 1.0;     // Risk Scaling Factor (% of balance per trade, Risk % mode)
input bool     EnableRandomizer   = true;    // Random +/- 0.1-0.3 point micro-offsets (prop firm)
input bool     VerboseLog         = false; // Print daily-reset messages to the Experts log

input group " === SMALL ACCOUNT MODE (e.g. $200 on Raw Spread) === "
input bool     SmallAccountMode   = false;  // Trade the minimum lot and tighten the SL to the risk budget below (off = full stop-loss)
input double   SmallRiskPct       = 1.0;    // Max loss per trade (% of balance) when SmallAccountMode is on

input group " === PROP FIRM SAFETY === "
input bool     DailyDDHalt        = false;  // Daily equity DD halt: closes all positions and pauses until next day (off = disabled)
input double   DailyDrawdownCapPct = 2.5;    // Daily equity drawdown level for the halt above (%)
input double   MaxDrawdownCapPct   = 8.0;    // Peak-to-trough equity drawdown hard stop (%): halts EA
input bool     MaxDDResetsDaily    = true;   // Max-DD halt lifts at the next trading day (peak reset); false = halt until restart
input double   MaxTotalRiskPct     = 0.0;    // Max money at risk on open positions + pending orders (% of balance). 0 = off

input group " === PROP AND ENTRY ADJUSTMENTS (points) === "
input double   AdjustEntry       = 0;        // Adjust Entry (+ = pending price moves up)
input double   AdjustSL          = 0;        // Adjust SL (+ = wider stop)
input double   AdjustTP          = 0;        // Adjust TP (+ = wider target)
input double   AdjustTrailSL     = 0;        // Adjust Trail SL distance (+ = wider trail)
input double   AdjustSalvageExit = 0;        // Adjust Salvage Exit (+ = exit further toward profit)
input double   AdjustBreakEven   = 0;        // Adjust Breakeven lock (+ = more profit locked)

input group " === TIMEFRAMES & FRACTALS === "
input ENUM_TIMEFRAMES fractalTf       = PERIOD_H1;   // Fractal timeframe for Sub-Strategy #9
input ENUM_TIMEFRAMES rescanTf        = PERIOD_M15;  // Entry rescan timeframe (order placement check)
input ENUM_TIMEFRAMES exitScanTf      = PERIOD_M1;   // Position management scan timeframe
input int      fractalLeft            = 5;           // Fractal left bars (Sub-Strategy #9)
input int      fractalRight           = 5;           // Fractal right bars (Sub-Strategy #9)
input int      fractalMaxSearch       = 200;         // Fractal max search (bars)
input double   fractalMinDistPct      = 0.02;        // Fractal min clearance from price (% of price)

input group " === ORDER MANAGEMENT === "
input int      maxPendingOrders       = 3;          // Max pending orders per sub-strategy per side
input int      pendingExpiryHours     = 15;         // Pending order expiration (hours, virtual)
input int      maxPositions           = 10;         // Max open positions (all sub-strategies)
input double   pendDedupDist          = 5;          // Pending dedup distance (points)

input group " === STRATEGY #9 (BASE BENCHMARK) === "
input double   buyEntryPct            = -0.08;      // Buy entry offset (% of swing high; negative = below high)
input double   sellEntryPct           = 0.08;       // Sell entry offset (% of swing low; positive = above low)
input double   slPct                  = 2.0;        // Stop Loss (% of price)
input double   tpPct                  = 0.7;        // Take Profit (% of price)
input double   trailPct               = 0.2;        // Trailing SL distance (% of price)
input double   trailMinProfitPct      = 0.2;        // Trailing SL trigger profit (% of price)
input double   trailMaxSLPct          = 1.0;        // Trailing distance cap (% of price)
input double   salvageTriggerPct      = 1.0;        // Salvage trigger floating loss (% of price)
input double   salvageExitPct         = 0.15;       // Salvage exit: TP placed this % into the loss
input double   beTriggerPct           = 0.1;        // Break-even trigger profit (% of price)
input double   beLockPct              = 0.025;      // Break-even lock profit (% of price)
input double   riskweight             = 0.055;      // Strategy risk weighting (base for all sub-strategies)

input group " === DASHBOARD === "
input bool     ShowDashboard      = true;   // Show the on-chart status panel

input group " === SUB-STRATEGY SWITCHES === "
input bool     Strategy1_Enabled      = true;
input bool     Strategy2_Enabled      = true;
input bool     Strategy3_Enabled      = true;
input bool     Strategy4_Enabled      = true;
input bool     Strategy5_Enabled      = true;
input bool     Strategy6_Enabled      = true;
input bool     Strategy7_Enabled      = true;
input bool     Strategy8_Enabled      = true;
input bool     Strategy9_Enabled      = true;

//+------------------------------------------------------------------+
//| Types                                                            |
//+------------------------------------------------------------------+
struct StrategyConfig
  {
   int             strategyId;           // Strategy index (1..9)
   long            magicNumber;          // InpMagic + (strategyId - 1)
   ENUM_TIMEFRAMES timeframe;            // Fractal timeframe
   int             fractalLeft;          // Left bars
   int             fractalRight;         // Right bars
   double          buyOffsetPct;         // Buy stop offset vs swing high (%)
   double          sellOffsetPct;        // Sell stop offset vs swing low (%)
   double          stopLossPct;          // Stop loss (%)
   double          takeProfitPct;        // Take profit (%)
   double          breakEvenTriggerPct;  // Break-even activation (%)
   double          breakEvenLockPct;     // Profit locked at break-even (%)
   double          trailingTriggerPct;   // Trailing activation (%)
   double          trailingDistPct;      // Trailing distance (%)
   double          salvageTriggerPct;    // Salvage activation: floating loss (%)
   double          salvageTargetPct;     // Salvage exit target, negative = loss side (%)
   double          riskWeight;           // Relative risk weight
   bool            enabled;              // Sub-strategy switch
  };

struct SwingState
  {
   bool            hiFound;
   double          hi;
   datetime        hiTime;
   bool            loFound;
   double          lo;
   datetime        loTime;
   datetime        lastBuySwing;         // swing time already used for a buy stop (one order per swing)
   datetime        lastSellSwing;        // swing time already used for a sell stop
   datetime        lastFractalBar;       // last processed bar on the fractal timeframe
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
StrategyConfig g_cfg[STRATEGY_COUNT];
SwingState     g_sw[STRATEGY_COUNT];
CTrade         g_trade;

double   g_point         = 0.0;
int      g_digits        = 0;
double   g_stopLevel     = 0.0;   // broker minimum stop distance (price units)
double   g_tierLevel     = 1.0;   // TieredLot clamped to 1..100

double   g_peakEquity    = 0.0;
double   g_dayStartEq    = 0.0;
int      g_dayKey        = 0;
bool     g_dayHalt       = false; // daily stop hit: no trading until next day
bool     g_maxDDHalt     = false; // max drawdown hit: EA halted
double   g_worstDDPct    = 0.0;   // largest equity drawdown seen so far (%), shown on the panel
datetime g_dashLast      = 0;     // last panel refresh

datetime g_lastRescanBar = 0;
int      g_riskSkipDayKey = 0;  // day on which an open-risk skip was last logged
int      g_lotSkipDayKey = 0;   // day on which a "lot below minimum" skip was last logged
datetime g_lastExitBar   = 0;

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
long MagicOf(const int idx)
  {
   return (long)InpMagic + idx;
  }

bool IsEAMagic(const long magic)
  {
   return (magic >= (long)InpMagic && magic < (long)InpMagic + STRATEGY_COUNT);
  }

// Position/Order ownership check: this symbol and one of our 9 magic numbers
bool IsEAPosition()
  {
   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
   return IsEAMagic(PositionGetInteger(POSITION_MAGIC));
  }

bool IsEAOrder()
  {
   if(OrderGetString(ORDER_SYMBOL) != _Symbol) return false;
   return IsEAMagic(OrderGetInteger(ORDER_MAGIC));
  }

int CountEAPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(IsEAPosition()) n++;
     }
   return n;
  }

// Count pending orders of one side for one sub-strategy; also returns the worst-priced one.
// Worst = highest price for buy stops, lowest price for sell stops.
void PendingStats(const int idx, const ENUM_ORDER_TYPE side, int &count, double &worstPx, ulong &worstTk)
  {
   count   = 0;
   worstPx = 0.0;
   worstTk = 0;
   long magic = MagicOf(idx);
   bool isBuy = (side == ORDER_TYPE_BUY_STOP);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic) continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != side) continue;
      double p = OrderGetDouble(ORDER_PRICE_OPEN);
      count++;
      if(worstTk == 0 || (isBuy ? (p > worstPx) : (p < worstPx)))
        {
         worstPx = p;
         worstTk = t;
        }
     }
  }

// True if a pending order of the same side already sits within 'dist' of 'price'
bool HasNearPending(const int idx, const ENUM_ORDER_TYPE side, const double price, const double dist)
  {
   long magic = MagicOf(idx);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic) continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != side) continue;
      if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - price) <= dist) return true;
     }
   return false;
  }

// Loss (positive money) for 'vol' lots from entry to sl. Returns false if the broker calc fails.
bool LossAtPrice(const ENUM_ORDER_TYPE otype, const double vol, const double entry, const double sl, double &loss)
  {
   double p = 0.0;
   if(!OrderCalcProfit(otype, _Symbol, vol, entry, sl, p)) return false;
   loss = MathAbs(p);
   return true;
  }

// Money lost if 'sl' is hit (0 when the stop is at or beyond the entry). Returns -1 if the broker calc fails.
double RiskOfOrder(const ENUM_ORDER_TYPE otype, const double vol, const double entry, const double sl)
  {
   if(sl <= 0.0 || vol <= 0.0) return 0.0;
   double p = 0.0;
   if(!OrderCalcProfit(otype, _Symbol, vol, entry, sl, p)) return -1.0;
   return MathMax(0.0, -p);
  }

// Total money at risk on EA positions and EA pending orders. Returns a huge number if any calc fails (blocks trading).
double OpenRiskMoney()
  {
   double total = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!IsEAPosition()) continue;
      bool isBuy = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double r = RiskOfOrder(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, PositionGetDouble(POSITION_VOLUME),
                             PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_SL));
      if(r < 0.0) return 1e18;
      total += r;
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(!IsEAOrder()) continue;
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool isBuy = (ot == ORDER_TYPE_BUY_STOP || ot == ORDER_TYPE_BUY_LIMIT || ot == ORDER_TYPE_BUY_STOP_LIMIT);
      double r = RiskOfOrder(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, OrderGetDouble(ORDER_VOLUME_CURRENT),
                             OrderGetDouble(ORDER_PRICE_OPEN), OrderGetDouble(ORDER_SL));
      if(r < 0.0) return 1e18;
      total += r;
     }
   return total;
  }

// Random micro-offset in price units: +/- (0.1 .. 0.3) points
double RandomOffset()
  {
   if(!EnableRandomizer) return 0.0;
   double mag  = 0.1 + 0.2 * ((double)MathRand() / 32767.0);
   double sign = (MathRand() % 2 == 0) ? 1.0 : -1.0;
   return sign * mag * _Point;
  }

// Sub-strategy weight relative to the base risk weighting (riskweight input)
double CalcWeight(const int idx)
  {
   if(riskweight <= 0.0 || g_cfg[idx].riskWeight <= 0.0) return 1.0;
   return g_cfg[idx].riskWeight / riskweight;
  }

bool IsBetterSL(const bool isBuy, const double curSL, const double newSL)
  {
   if(curSL <= 0.0) return true;
   return isBuy ? (newSL > curSL + _Point / 2.0) : (newSL < curSL - _Point / 2.0);
  }

// Stop level must sit on the correct side of the current price, at least the broker minimum away
bool IsValidSL(const bool isBuy, const double cur, const double sl)
  {
   double d = isBuy ? (cur - sl) : (sl - cur);
   return (d > 0.0 && d >= g_stopLevel);
  }

bool IsValidTP(const bool isBuy, const double cur, const double tp)
  {
   double d = isBuy ? (tp - cur) : (cur - tp);
   return (d > 0.0 && d >= g_stopLevel);
  }

//+------------------------------------------------------------------+
//| Strategy configuration (spec section 4.2)                        |
//+------------------------------------------------------------------+
void InitStrategyConfig()
  {
   // ---- Sub-Strategy #9: base benchmark, uses the input parameters ----
   StrategyConfig c9;
   c9.strategyId          = 9;
   c9.magicNumber         = MagicOf(8);
   c9.timeframe           = fractalTf;
   c9.fractalLeft         = fractalLeft;
   c9.fractalRight        = fractalRight;
   c9.buyOffsetPct        = buyEntryPct;
   c9.sellOffsetPct       = sellEntryPct;
   c9.stopLossPct         = slPct;
   c9.takeProfitPct       = tpPct;
   c9.breakEvenTriggerPct = beTriggerPct;
   c9.breakEvenLockPct    = beLockPct;
   c9.trailingTriggerPct  = trailMinProfitPct;
   c9.trailingDistPct     = trailPct;
   c9.salvageTriggerPct   = salvageTriggerPct;
   c9.salvageTargetPct    = -salvageExitPct;   // spec: exit target sits in the loss zone
   c9.riskWeight          = riskweight;
   c9.enabled             = Strategy9_Enabled;
   g_cfg[8] = c9;

   // ---- Sub-Strategies #1..#8: diversified presets from spec section 4.2 ----
   ENUM_TIMEFRAMES tfList[8]   = {PERIOD_M1, PERIOD_M5, PERIOD_M5, PERIOD_M15, PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H1};
   int             leftList[8] = {3, 3, 5, 5, 7, 5, 5, 7};
   double          offsets[8]  = {-0.04, -0.05, -0.06, -0.08, -0.10, -0.12, -0.15, -0.18};
   bool            enables[8];
   enables[0] = Strategy1_Enabled; enables[1] = Strategy2_Enabled;
   enables[2] = Strategy3_Enabled; enables[3] = Strategy4_Enabled;
   enables[4] = Strategy5_Enabled; enables[5] = Strategy6_Enabled;
   enables[6] = Strategy7_Enabled; enables[7] = Strategy8_Enabled;

   for(int i = 0; i < 8; i++)
     {
      StrategyConfig c;
      c.strategyId          = i + 1;
      c.magicNumber         = MagicOf(i);
      c.timeframe           = tfList[i];
      c.fractalLeft         = leftList[i];
      c.fractalRight        = leftList[i];
      c.buyOffsetPct        = offsets[i];
      c.sellOffsetPct       = -offsets[i];
      c.stopLossPct         = 1.5 + i * 0.15;
      c.takeProfitPct       = 0.5 + i * 0.08;
      c.breakEvenTriggerPct = 0.08 + i * 0.01;
      c.breakEvenLockPct    = 0.02;
      c.trailingTriggerPct  = 0.15 + i * 0.02;
      c.trailingDistPct     = 0.15;
      c.salvageTriggerPct   = c.stopLossPct * 0.5;
      c.salvageTargetPct    = -0.10;
      c.riskWeight          = 0.05 + i * 0.005;
      c.enabled             = enables[i];
      g_cfg[i] = c;
     }
  }

//+------------------------------------------------------------------+
//| Fractal detection (spec section 5.A)                             |
//| Candidate bar = shift (right + 1). The 'right' bars are newer,   |
//| the 'left' bars are older. Strict inequality: candidate must be  |
//| strictly the highest (or lowest) of its neighbourhood.           |
//+------------------------------------------------------------------+
bool IsFractalHigh(const double &hi[], const int k, const int L, const int R)
  {
   double v = hi[k];
   for(int j = 1; j <= R; j++)
      if(hi[k - j] >= v) return false;
   for(int j = 1; j <= L; j++)
      if(hi[k + j] >= v) return false;
   return true;
  }

bool IsFractalLow(const double &lo[], const int k, const int L, const int R)
  {
   double v = lo[k];
   for(int j = 1; j <= R; j++)
      if(lo[k - j] <= v) return false;
   for(int j = 1; j <= L; j++)
      if(lo[k + j] <= v) return false;
   return true;
  }

// Finds the most recent valid swing high and swing low for one sub-strategy.
void ScanFractals(const int idx)
  {
   StrategyConfig c = g_cfg[idx];
   int L   = c.fractalLeft;
   int R   = c.fractalRight;
   int cand = R + 1;

   g_sw[idx].hiFound = false;
   g_sw[idx].loFound = false;

   int avail = Bars(_Symbol, c.timeframe);
   int maxK  = MathMin(fractalMaxSearch, avail - L - 2);
   if(maxK < cand) return;

   int count = maxK + L + 1;
   double hi[], lo[];
   datetime tm[];
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   ArraySetAsSeries(tm, true);
   if(CopyHigh(_Symbol, c.timeframe, 0, count, hi) < count) return;
   if(CopyLow(_Symbol, c.timeframe, 0, count, lo) < count) return;
   if(CopyTime(_Symbol, c.timeframe, 0, count, tm) < count) return;

   for(int k = cand; k <= maxK; k++)
     {
      if(!g_sw[idx].hiFound && IsFractalHigh(hi, k, L, R))
        {
         g_sw[idx].hiFound = true;
         g_sw[idx].hi      = hi[k];
         g_sw[idx].hiTime  = tm[k];
        }
      if(!g_sw[idx].loFound && IsFractalLow(lo, k, L, R))
        {
         g_sw[idx].loFound = true;
         g_sw[idx].lo      = lo[k];
         g_sw[idx].loTime  = tm[k];
        }
      if(g_sw[idx].hiFound && g_sw[idx].loFound) break;
     }
  }

//+------------------------------------------------------------------+
//| Lot sizing                                                       |
//+------------------------------------------------------------------+
double CalcLots(const ENUM_ORDER_TYPE otype, const double entry, const double sl, const double weight)
  {
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), MAX_LOT_CAP);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(minLot <= 0.0 || maxLot <= 0.0 || step <= 0.0) return 0.0;

   double lots = 0.0;
   if(Lotsizing_Method == LOT_FIXED)
     {
      lots = FixedLots;
     }
   else
     {
      // Tiered: meter 1..100 maps linearly onto 0..TieredMaxRiskPct of balance.
      // Risk %: RiskScaling is the % of balance risked per trade.
      double riskPct = (Lotsizing_Method == LOT_TIERED)
                       ? TieredMaxRiskPct * g_tierLevel / 100.0
                       : RiskScaling;
      riskPct *= weight;
      double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * riskPct / 100.0;

      double profitAt1Lot = 0.0;
      if(!OrderCalcProfit(otype, _Symbol, 1.0, entry, sl, profitAt1Lot)) return 0.0;
      double lossAt1Lot = MathAbs(profitAt1Lot);
      if(lossAt1Lot <= 0.0 || riskMoney <= 0.0) return 0.0;
      lots = riskMoney / lossAt1Lot;

      // Balance needed for the requested risk to reach the minimum lot
      double minLotRisk = minLot * lossAt1Lot;
      if(lots < minLot && g_lotSkipDayKey != g_dayKey)
        {
         g_lotSkipDayKey = g_dayKey;
         Print(StringFormat("Gold X9: trade skipped. Risk-based lot %.5f is below the minimum %.2f. "
                            "At %.2f%% risk and this stop distance, the minimum lot needs a balance of about %.0f USD "
                            "(current balance %.2f). Raise the balance, raise the risk %%, or use Fixed Lots.",
                            lots, minLot, riskPct, minLotRisk / (riskPct / 100.0),
                            AccountInfoDouble(ACCOUNT_BALANCE)));
        }
     }

   lots = MathMin(lots, maxLot);
   lots = MathFloor(lots / step + 1e-7) * step;

   int volDigits = 2;
   if(step < 1.0) volDigits = (int)MathRound(-MathLog10(step));
   volDigits = (int)MathMax(0.0, MathMin(8.0, (double)volDigits));
   lots = NormalizeDouble(lots, volDigits);

   if(lots < minLot)
     {
      if(Lotsizing_Method == LOT_FIXED) lots = minLot;
      else return 0.0;   // risk mode: do not exceed the requested risk
     }
   if(lots > maxLot) lots = maxLot;
   return lots;
  }

//+------------------------------------------------------------------+
//| Order placement (spec section 5.B)                               |
//+------------------------------------------------------------------+
void TryPlaceStop(const int idx, const bool isBuy, const double swingLevel, const datetime swingTime)
  {
   StrategyConfig c = g_cfg[idx];

   // One order per swing per side: never re-arm a swing that already produced an order
   if(isBuy && swingTime == g_sw[idx].lastBuySwing) return;
   if(!isBuy && swingTime == g_sw[idx].lastSellSwing) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0 || swingLevel <= 0.0) return;

   // Minimum clearance between the fractal and current price
   double clearPct = MathAbs(swingLevel - bid) / bid * 100.0;
   if(clearPct < fractalMinDistPct) return;

   // Entry: swing level offset by the strategy percentage
   double offPct = isBuy ? c.buyOffsetPct : c.sellOffsetPct;
   double entry  = swingLevel * (1.0 + offPct / 100.0) + AdjustEntry * _Point + RandomOffset();
   entry = NormalizeDouble(entry, _Digits);

   // Stop orders must sit on the correct side of market by at least the broker minimum
   if(isBuy)
     {
      double d = entry - ask;
      if(d <= 0.0 || d < g_stopLevel) return;
     }
   else
     {
      double d = bid - entry;
      if(d <= 0.0 || d < g_stopLevel) return;
     }

   ENUM_ORDER_TYPE side = isBuy ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;

   // Duplicate guard (DuplicatePointGap)
   if(HasNearPending(idx, side, entry, pendDedupDist * _Point)) return;

   // Stop loss and take profit as percentages of the entry price
   double slDist = entry * c.stopLossPct / 100.0 + AdjustSL * _Point;
   double tpDist = entry * c.takeProfitPct / 100.0 + AdjustTP * _Point;
   double sl = NormalizeDouble((isBuy ? entry - slDist : entry + slDist) + RandomOffset(), _Digits);
   double tp = NormalizeDouble((isBuy ? entry + tpDist : entry - tpDist) + RandomOffset(), _Digits);
   if(!IsValidSL(isBuy, entry, sl) || !IsValidTP(isBuy, entry, tp)) return;

   ENUM_ORDER_TYPE otype = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double lots = 0.0;
   if(SmallAccountMode)
     {
      // Trade the minimum lot. If one stop-out at this SL costs more than the budget,
      // move the SL closer (linear in distance) so the loss equals the budget.
      lots = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double budget = AccountInfoDouble(ACCOUNT_BALANCE) * SmallRiskPct / 100.0;
      double lossAtSL = 0.0;
      if(!LossAtPrice(otype, lots, entry, sl, lossAtSL)) return;
      if(budget <= 0.0) return;
      if(lossAtSL > budget)
        {
         double k       = budget / lossAtSL;
         double newDist = MathAbs(entry - sl) * k;
         double spread  = ask - bid;
         if(newDist < g_stopLevel || newDist < 2.0 * spread)
           {
            Print(StringFormat("Gold X9 S%d skipped: small-account stop %.2f would be inside the spread/stop level.",
                               c.strategyId, newDist));
            return;
           }
         sl = NormalizeDouble(isBuy ? entry - newDist : entry + newDist, _Digits);
         if(!IsValidSL(isBuy, entry, sl)) return;
        }
     }
   else
     {
      lots = CalcLots(otype, entry, sl, CalcWeight(idx));
     }
   if(lots <= 0.0) return;

   // Total open-risk cap: positions + pending orders (this order included) may not exceed MaxTotalRiskPct
   if(MaxTotalRiskPct > 0.0)
     {
      double newRisk = RiskOfOrder(otype, lots, entry, sl);
      double capMoney = AccountInfoDouble(ACCOUNT_BALANCE) * MaxTotalRiskPct / 100.0;
      double openRisk = OpenRiskMoney();
      if(newRisk < 0.0 || openRisk + newRisk > capMoney)
        {
      if(g_riskSkipDayKey != g_dayKey)
        {
         g_riskSkipDayKey = g_dayKey;
         Print(StringFormat("Gold X9: order skipped. Open risk %.2f + new %.2f would exceed the cap %.2f (%.1f%% of balance).",
                            openRisk, newRisk, capMoney, MaxTotalRiskPct));
        }
      return;
     }
     }

   // Max pending orders: replace the worst-priced one only if the new order is superior
   int    pendCount = 0;
   double worstPx   = 0.0;
   ulong  worstTk   = 0;
   PendingStats(idx, side, pendCount, worstPx, worstTk);
   if(pendCount >= maxPendingOrders)
     {
      if(worstTk == 0) return;
      bool superior = isBuy ? (entry < worstPx) : (entry > worstPx);
      if(!superior) return;
      if(!g_trade.OrderDelete(worstTk))
        {
         Print("Gold X9: could not replace worst pending order #", worstTk, " - ", g_trade.ResultRetcodeDescription());
         return;
        }
     }


   g_trade.SetExpertMagicNumber((ulong)c.magicNumber);
   string cmt = StringFormat("%s S%d", TradeComment, c.strategyId);

   bool ok = isBuy
             ? g_trade.BuyStop(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt)
             : g_trade.SellStop(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt);

   if(ok)
     {
      if(isBuy) g_sw[idx].lastBuySwing  = swingTime;
      else      g_sw[idx].lastSellSwing = swingTime;
      Print(StringFormat("Gold X9 S%d %s STOP placed: entry %s  SL %s  TP %s  lots %s",
                         c.strategyId, isBuy ? "BUY" : "SELL",
                         DoubleToString(entry, _Digits), DoubleToString(sl, _Digits),
                         DoubleToString(tp, _Digits), DoubleToString(lots, 2)));
     }
   else
     {
      Print(StringFormat("Gold X9 S%d order failed: %s", c.strategyId, g_trade.ResultRetcodeDescription()));
     }
  }

void PlaceOrders(const int idx)
  {
   if(CountEAPositions() >= maxPositions) return;
   if(g_sw[idx].hiFound) TryPlaceStop(idx, true,  g_sw[idx].hi, g_sw[idx].hiTime);
   if(g_sw[idx].loFound) TryPlaceStop(idx, false, g_sw[idx].lo, g_sw[idx].loTime);
  }

//+------------------------------------------------------------------+
//| Pending order expiry (virtual expiration, spec section 1)        |
//+------------------------------------------------------------------+
void ExpirePendingOrders()
  {
   long now = (long)TimeCurrent();
   long limit = (long)pendingExpiryHours * 3600;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(!IsEAOrder()) continue;
      long setup = (long)OrderGetInteger(ORDER_TIME_SETUP);
      if(now - setup >= limit)
         g_trade.OrderDelete(t);
     }
  }

//+------------------------------------------------------------------+
//| Position management (spec section 5.C)                           |
//| Order: Salvage -> Break-even -> Trailing. SL only moves forward. |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!IsEAPosition()) continue;

      long magic = PositionGetInteger(POSITION_MAGIC);
      int  idx   = (int)(magic - (long)InpMagic);
      StrategyConfig c = g_cfg[idx];

      bool isBuy = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double cur  = isBuy ? bid : ask;
      if(open <= 0.0 || cur <= 0.0) continue;

      double profitPct = isBuy ? (cur - open) / open * 100.0 : (open - cur) / open * 100.0;

      // 1) Salvage: once floating loss reaches the trigger, pull TP into the small-loss zone
      if(profitPct <= -c.salvageTriggerPct)
        {
         double target = isBuy ? open * (1.0 + c.salvageTargetPct / 100.0)
                               : open * (1.0 - c.salvageTargetPct / 100.0);
         target += (isBuy ? AdjustSalvageExit : -AdjustSalvageExit) * _Point;
         target  = NormalizeDouble(target, _Digits);
         if(MathAbs(target - tp) > _Point / 2.0 && IsValidTP(isBuy, cur, target))
           {
            if(g_trade.PositionModify(t, sl, target)) tp = target;
           }
        }

      // 2) Break-even lock
      if(profitPct >= c.breakEvenTriggerPct)
        {
         double beSL = isBuy ? open * (1.0 + c.breakEvenLockPct / 100.0)
                             : open * (1.0 - c.breakEvenLockPct / 100.0);
         beSL += (isBuy ? AdjustBreakEven : -AdjustBreakEven) * _Point;
         beSL  = NormalizeDouble(beSL, _Digits);
         if(IsBetterSL(isBuy, sl, beSL) && IsValidSL(isBuy, cur, beSL))
           {
            if(g_trade.PositionModify(t, beSL, tp)) sl = beSL;
           }
        }

      // 3) Trailing stop (distance capped by trailMaxSLPct)
      if(profitPct >= c.trailingTriggerPct)
        {
         double distPct = MathMin(c.trailingDistPct, trailMaxSLPct);
         double dist    = cur * distPct / 100.0 + AdjustTrailSL * _Point;
         double tsl     = NormalizeDouble(isBuy ? cur - dist : cur + dist, _Digits);
         if(IsBetterSL(isBuy, sl, tsl) && IsValidSL(isBuy, cur, tsl))
           {
            g_trade.PositionModify(t, tsl, tp);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Closing helpers                                                  |
//+------------------------------------------------------------------+
void DeletePendingsEA()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(IsEAOrder()) g_trade.OrderDelete(t);
     }
  }

void ClosePositionsEA()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(IsEAPosition()) g_trade.PositionClose(t);
     }
  }

void CloseAllEA()
  {
   ClosePositionsEA();
   DeletePendingsEA();
  }

//+------------------------------------------------------------------+
//| Prop-firm equity guards (spec section 1 and 2)                   |
//+------------------------------------------------------------------+
void UpdateRiskGuards()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);

   MqlDateTime dt;
   TimeCurrent(dt);
   int key = dt.year * 10000 + dt.mon * 100 + dt.day;
   if(key != g_dayKey)
     {
      g_dayKey     = key;
      g_dayStartEq = eq;
      g_dayHalt    = false;
      if(MaxDDResetsDaily && g_maxDDHalt)
        {
         g_maxDDHalt  = false;
         g_peakEquity = eq;      // measure the next drawdown from today's equity
         Print("Gold X9: max-drawdown halt lifted for the new trading day.");
        }
      if(VerboseLog)
         Print("Gold X9: new trading day, daily equity reference reset to ", DoubleToString(eq, 2));
     }

   if(eq > g_peakEquity) g_peakEquity = eq;
   if(g_peakEquity > 0.0)
     {
      double ddNow = (g_peakEquity - eq) / g_peakEquity * 100.0;
      if(ddNow > g_worstDDPct) g_worstDDPct = ddNow;
     }

   // Daily equity drawdown hard stop: close everything, no trading until next day
   if(DailyDDHalt && !g_dayHalt && g_dayStartEq > 0.0)
     {
      double ddDay = (g_dayStartEq - eq) / g_dayStartEq * 100.0;
      if(ddDay > DailyDrawdownCapPct)
        {
         Print(StringFormat("Gold X9: daily drawdown %.2f%% > %.2f%%. Closing all EA trades.", ddDay, DailyDrawdownCapPct));
         CloseAllEA();
         g_dayHalt = true;
        }
     }

   // Peak-to-trough drawdown hard stop: halt the EA (no new orders; open trades still managed)
   if(!g_maxDDHalt && g_peakEquity > 0.0)
     {
      double ddMax = (g_peakEquity - eq) / g_peakEquity * 100.0;
      if(ddMax > MaxDrawdownCapPct)
        {
         Print(StringFormat("Gold X9: max drawdown %.2f%% > %.2f%%. EA halted%s.", ddMax, MaxDrawdownCapPct,
                            MaxDDResetsDaily ? " until the next trading day" : " until restart"));
         g_maxDDHalt = true;
         DeletePendingsEA();
        }
     }
  }

//+------------------------------------------------------------------+
//| Init / Deinit / Tick                                             |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| On-chart dashboard                                               |
//+------------------------------------------------------------------+
#define DASH_PREFIX "GX9_"
#define DASH_X0     10
#define DASH_Y0     20
#define DASH_FONT   "Consolas"
#define DASH_SIZE   9

int DashY(const int row)
  {
   return DASH_Y0 + 12 + row * 16;
  }

void DashLabel(const string name, const int x, const int y, const int size, const color clr)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, name, OBJPROP_FONT, DASH_FONT);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
  }

void DashSet(const string name, const string text, const color clr)
  {
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

// Creates the panel background and all labels (called once from OnInit)
void DashCreate()
  {
   string bg = DASH_PREFIX + "BG";
   if(ObjectFind(0, bg) < 0)
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, DASH_X0);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, DASH_Y0);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, 330);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, DashY(19) - DASH_Y0 + 24);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'18,18,18');
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bg, OBJPROP_COLOR, C'80,80,80');
   ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, bg, OBJPROP_BACK, false);

   // Title
   DashLabel(DASH_PREFIX + "TITLE", DASH_X0 + 10, DashY(0), 10, clrOrange);
   DashSet(DASH_PREFIX + "TITLE", "Gold X9", clrOrange);
   DashLabel(DASH_PREFIX + "BY", DASH_X0 + 88, DashY(0), DASH_SIZE, clrWhite);
   DashSet(DASH_PREFIX + "BY", "by AIT CHIKH MUSTAPHA", clrWhite);

   // Summary rows 1..7
   string keys[7] = {"Status", "Trade frequency", "Account balance", "Max allowed DD",
                     "Max DD (Equity)", "Open P/L", "Total P/L"};
   for(int r = 0; r < 7; r++)
     {
      DashLabel(DASH_PREFIX + "K" + IntegerToString(r), DASH_X0 + 10, DashY(r + 1), DASH_SIZE, clrSilver);
      DashSet(DASH_PREFIX + "K" + IntegerToString(r), keys[r], clrSilver);
      DashLabel(DASH_PREFIX + "V" + IntegerToString(r), DASH_X0 + 150, DashY(r + 1), DASH_SIZE, clrWhite);
     }

   // Table header (row 9) and strategy rows (10..18), total (19)
   DashLabel(DASH_PREFIX + "HDR", DASH_X0 + 10, DashY(9), DASH_SIZE, clrSilver);
   DashSet(DASH_PREFIX + "HDR", StringFormat("%-11s%6s%10s%9s%6s", "Strategy", "Trades", "Closed", "Per trd", "Lots"), clrSilver);
   for(int i = 0; i < STRATEGY_COUNT; i++)
      DashLabel(DASH_PREFIX + "T" + IntegerToString(i), DASH_X0 + 10, DashY(10 + i), DASH_SIZE, clrWhite);
   DashLabel(DASH_PREFIX + "TOT", DASH_X0 + 10, DashY(19), DASH_SIZE, clrWhite);
   ChartRedraw(0);
  }

// Closed-trade statistics are cached. They are rebuilt only after a trade event or a new day,
// because reading the whole history is slow in the Strategy Tester.
double   g_cPL[STRATEGY_COUNT];
int      g_cTrades[STRATEGY_COUNT];
double   g_cTotalPL = 0.0;
int      g_cRecent  = 0;
bool     g_histDirty = true;
int      g_histDay   = 0;

void DashRefreshHistory()
  {
   ArrayInitialize(g_cPL, 0.0);
   ArrayInitialize(g_cTrades, 0);
   g_cTotalPL = 0.0;
   g_cRecent  = 0;

   datetime now = TimeCurrent();
   if(HistorySelect(0, now))
     {
      int n = HistoryDealsTotal();
      for(int i = 0; i < n; i++)
        {
         ulong tk = HistoryDealGetTicket(i);
         if(tk == 0) continue;
         if(HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol) continue;
         long magic = HistoryDealGetInteger(tk, DEAL_MAGIC);
         if(!IsEAMagic(magic)) continue;
         int idx = (int)(magic - (long)InpMagic);

         double pl = HistoryDealGetDouble(tk, DEAL_PROFIT)
                   + HistoryDealGetDouble(tk, DEAL_COMMISSION)
                   + HistoryDealGetDouble(tk, DEAL_SWAP);
         g_cPL[idx] += pl;
         g_cTotalPL += pl;

         long entry = HistoryDealGetInteger(tk, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
           {
            g_cTrades[idx]++;
            if(now - (datetime)HistoryDealGetInteger(tk, DEAL_TIME) <= 7 * 86400) g_cRecent++;
           }
        }
     }
   g_histDirty = false;
   g_histDay   = g_dayKey;
  }

// Draws the panel. Open positions are read live; closed stats come from the cache.
void DashRender()
  {
   double openPL = 0.0;
   double openLots[STRATEGY_COUNT];
   ArrayInitialize(openLots, 0.0);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!IsEAPosition()) continue;
      int idx = (int)(PositionGetInteger(POSITION_MAGIC) - (long)InpMagic);
      openLots[idx] += PositionGetDouble(POSITION_VOLUME);
      openPL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }

   double perDay = g_cRecent / 7.0;
   string freq = (perDay < 1.0) ? "Low" : (perDay <= 5.0 ? "Moderate" : "High");

   bool anyOn = false;
   for(int i = 0; i < STRATEGY_COUNT; i++)
      if(g_cfg[i].enabled) anyOn = true;
   string status = "Trading active";
   color  statusClr = clrLime;
   if(g_maxDDHalt)      { status = "Halted: max DD";       statusClr = clrTomato; }
   else if(g_dayHalt)   { status = "Halted: daily DD";     statusClr = clrTomato; }
   else if(!anyOn)      { status = "No sub-strategy on";   statusClr = clrOrange; }

   DashSet(DASH_PREFIX + "V0", status, statusClr);
   DashSet(DASH_PREFIX + "V1", StringFormat("%s (%.1f/day)", freq, perDay), clrWhite);
   DashSet(DASH_PREFIX + "V2", StringFormat("%.2f", AccountInfoDouble(ACCOUNT_BALANCE)), clrWhite);
   DashSet(DASH_PREFIX + "V3", StringFormat("%.1f%%", MaxDrawdownCapPct), clrOrange);
   DashSet(DASH_PREFIX + "V4", StringFormat("%.1f%%", g_worstDDPct), clrWhite);
   DashSet(DASH_PREFIX + "V5", StringFormat("%.2f", openPL), openPL >= 0.0 ? clrLime : clrTomato);
   DashSet(DASH_PREFIX + "V6", StringFormat("%.2f", g_cTotalPL), g_cTotalPL >= 0.0 ? clrLime : clrTomato);

   double sumClosed = 0.0, sumLots = 0.0;
   int    sumTrades = 0;
   for(int i = 0; i < STRATEGY_COUNT; i++)
     {
      double perTrd = (g_cTrades[i] > 0) ? g_cPL[i] / g_cTrades[i] : 0.0;
      color  clr = g_cfg[i].enabled ? (g_cPL[i] < 0.0 ? clrTomato : clrWhite) : clrGray;
      DashSet(DASH_PREFIX + "T" + IntegerToString(i),
              StringFormat("%-11s%6d%10.2f%9.2f%6.2f", "Strategy " + IntegerToString(i + 1),
                           g_cTrades[i], g_cPL[i], perTrd, openLots[i]), clr);
      sumTrades += g_cTrades[i];
      sumClosed += g_cPL[i];
      sumLots   += openLots[i];
     }
   double totPerTrd = (sumTrades > 0) ? sumClosed / sumTrades : 0.0;
   DashSet(DASH_PREFIX + "TOT",
           StringFormat("%-11s%6d%10.2f%9.2f%6.2f", "Total", sumTrades, sumClosed, totPerTrd, sumLots),
           clrWhite);
   ChartRedraw(0);
  }

void DashUpdate()
  {
   if(g_histDirty || g_histDay != g_dayKey) DashRefreshHistory();
   DashRender();
  }

// Any trade event (open, close, modify, cancel) means the closed-trade cache must be rebuilt
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   g_histDirty = true;
  }

int OnInit()
  {
   if(fractalLeft < 1 || fractalRight < 1)
     {
      Print("Gold X9: fractalLeft and fractalRight must be >= 1");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(fractalMaxSearch < 10 || maxPendingOrders < 1 || maxPositions < 1 || pendingExpiryHours < 1)
     {
      Print("Gold X9: invalid order/fractal parameters");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(FixedLots <= 0.0 || RiskScaling <= 0.0 || TieredMaxRiskPct <= 0.0)
     {
      Print("Gold X9: lot sizing parameters must be > 0");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(slPct <= 0.0 || tpPct <= 0.0)
     {
      Print("Gold X9: stop loss and take profit percentages must be > 0");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(g_point <= 0.0)
     {
      Print("Gold X9: cannot read symbol point size");
      return INIT_FAILED;
     }
   g_stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * g_point;

   if(!SmallAccountMode)
     {
      double px  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double bal = AccountInfoDouble(ACCOUNT_BALANCE);
      double loss = 0.0;
      if(px > 0.0 && bal > 0.0 && LossAtPrice(ORDER_TYPE_BUY, vol, px, px * (1.0 - slPct / 100.0), loss) && loss > bal * 0.02)
         Print(StringFormat("Gold X9 WARNING: at minimum lot %.2f a stop-loss costs %.2f (%.1f%% of balance %.2f). "
                            "Enable SmallAccountMode or use a larger balance.", vol, loss, loss / bal * 100.0, bal));
     }

   g_tierLevel = TieredLot;
   if(g_tierLevel > 100.0) g_tierLevel = 100.0;
   if(g_tierLevel <= 0.0)  g_tierLevel = 1.0;

   InitStrategyConfig();

   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);
   MathSrand((int)GetTickCount());

   g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayStartEq = g_peakEquity;
   MqlDateTime dt;
   TimeCurrent(dt);
   g_dayKey = dt.year * 10000 + dt.mon * 100 + dt.day;

   int active = 0;
   for(int i = 0; i < STRATEGY_COUNT; i++)
      if(g_cfg[i].enabled) active++;

   Print(StringFormat("Gold X9 V6.3 started on %s. Magic %d-%d. Active sub-strategies: %d/9",
                      _Symbol, InpMagic, InpMagic + STRATEGY_COUNT - 1, active));
   if(ShowDashboard)
     {
      DashCreate();
      DashUpdate();
      EventSetTimer(1);
     }
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   // Open positions and pending orders are left in place. Their SL/TP live on the broker side.
   EventKillTimer();
   ObjectsDeleteAll(0, DASH_PREFIX);
   Print("Gold X9 V6.3 stopped, reason code ", reason);
  }

void OnTick()
  {
   UpdateRiskGuards();

   bool trading = (!g_dayHalt && !g_maxDDHalt);

   // Daily stop: keep retrying the close-all until the account is flat (a close can fail on a busy server)
   if(g_dayHalt) CloseAllEA();

   // Once per bar of the exit-scan timeframe: position management, pending expiry, panel
   datetime exitBar = iTime(_Symbol, exitScanTf, 0);
   bool newExitBar = (exitBar != 0 && exitBar != g_lastExitBar);
   if(newExitBar)
     {
      g_lastExitBar = exitBar;
      ManagePositions();
      ExpirePendingOrders();
     }

   // Entry rescan runs on each new bar of the rescan timeframe
   datetime rescanBar = iTime(_Symbol, rescanTf, 0);
   bool newRescanBar = (rescanBar != 0 && rescanBar != g_lastRescanBar);
   if(newRescanBar) g_lastRescanBar = rescanBar;

   for(int i = 0; i < STRATEGY_COUNT; i++)
     {
      if(!g_cfg[i].enabled) continue;

      // Swing detection runs on each new bar of the sub-strategy's fractal timeframe
      datetime fBar = iTime(_Symbol, g_cfg[i].timeframe, 0);
      bool newFractal = (fBar != 0 && fBar != g_sw[i].lastFractalBar);
      if(newFractal)
        {
         g_sw[i].lastFractalBar = fBar;
         ScanFractals(i);
        }

      if(trading && (newFractal || newRescanBar))
         PlaceOrders(i);
     }

   if(ShowDashboard && (newExitBar || g_histDirty))
      DashUpdate();
  }

// Live refresh of open P/L between bars (live trading only; the tester skips timers)
void OnTimer()
  {
   if(ShowDashboard) DashRender();
  }
//+------------------------------------------------------------------+
