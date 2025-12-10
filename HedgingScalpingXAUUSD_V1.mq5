//+------------------------------------------------------------------+
//| HedgingScalpingXAUUSD.mq5                                       |
//| Hedging Scalping EA for XAUUSD - Min $10 Capital                |
//+------------------------------------------------------------------+
#property copyright "Trading Assistant"
#property version   "1.00"
#property strict

#include <TradeTrade.mqh>
#include <TradePositionInfo.mqh>

//--- Input Parameters
input group "=== Strategi Parameters ==="
input int    FastMA = 9;                       // Fast SMA Period
input int    SlowMA = 21;                      // Slow SMA Period
input int    RSIPeriod = 14;                   // RSI Period
input int    RSIOverbought = 70;               // RSI Overbought Level
input int    RSIOversold = 30;                 // RSI Oversold Level

input group "=== Risk Management ==="
input double RiskPercent = 1.0;                // Risk per trade (%)
input int    StopLossPips = 50;                // Stop Loss (pips)
input int    TakeProfitPips = 10;              // Take Profit (pips)
input double MaxDailyLossPercent = 5.0;        // Max Daily Loss (%)

input group "=== Hedging ==="
input int    HedgingSpreadPips = 3;            // Min Spread for Hedging (pips)
input bool   EnableTrailingStop = true;        // Enable Trailing Stop
input int    TrailingDistancePips = 8;         // Trailing Distance (pips)

input group "=== Position Control ==="
input int    MaxOpenPositions = 4;             // Max Open Positions
input bool   EnableMartingale = false;         // Enable Martingale
input double MartingaleMultiplier = 1.5;       // Martingale Lot Multiplier

input group "=== Time Filter ==="
input bool   EnableTimeFilter = false;         // Enable Time Filter
input int    StartHour = 14;                   // Start Hour (Server Time)
input int    EndHour = 22;                     // End Hour (Server Time)

input group "=== General ==="
input int    MagicNumber = 123456;             // Magic Number
input int    SlippagePips = 10;                // Slippage (pips)

//--- Global Variables
CTrade         trade;
CPositionInfo  position;
int            hFastMA, hSlowMA, hRSI;
double         dailyStartEquity = 0;
datetime       lastDayCheck = 0;
double         lastLotSize = 0.01;
double         pipSize = 0.1;  // XAUUSD typically 0.1 pip

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(_Symbol != "XAUUSD") {
      Alert("EA hanya untuk XAUUSD!");
      return(INIT_FAILED);
   }
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePips * 10);
   
   // Initialize indicators
   hFastMA = iMA(_Symbol, PERIOD_CURRENT, FastMA, 0, MODE_SMA, PRICE_CLOSE);
   hSlowMA = iMA(_Symbol, PERIOD_CURRENT, SlowMA, 0, MODE_SMA, PRICE_CLOSE);
   hRSI = iRSI(_Symbol, PERIOD_CURRENT, RSIPeriod, PRICE_CLOSE);
   
   if(hFastMA == INVALID_HANDLE || hSlowMA == INVALID_HANDLE || hRSI == INVALID_HANDLE) {
      Print("Gagal create indicators!");
      return(INIT_FAILED);
   }
   
   pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;  // XAUUSD pip
   dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   Print("Hedging Scalping XAUUSD EA initialized");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hFastMA);
   IndicatorRelease(hSlowMA);
   IndicatorRelease(hRSI);
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check new day for daily reset
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day != TimeToStruct(lastDayCheck, dt).day) {
      dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      lastDayCheck = TimeCurrent();
      lastLotSize = 0.01;
   }
   
   // Daily loss check
   if(!CheckDailyLoss()) return;
   
   // Time filter
   if(EnableTimeFilter && !IsTradeTime()) return;
   
   // Spread filter
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > HedgingSpreadPips * 10) return;
   
   // Manage existing positions
   if(EnableTrailingStop) TrailingPositions();
   ManageProfitablePositions();
   
   // Check for new signals if positions < max
   if(CountMyPositions() < MaxOpenPositions) {
      int signal = GetSignal();
      if(signal == 1) OpenHedgingPair(ORDER_TYPE_BUY);
      else if(signal == -1) OpenHedgingPair(ORDER_TYPE_SELL);
   }
   
   UpdateDashboard();
}

//+------------------------------------------------------------------+
//| Get Trading Signal                                               |
//+------------------------------------------------------------------+
int GetSignal()
{
   double fastMA[2], slowMA[2], rsi[2];
   
   if(CopyBuffer(hFastMA, 0, 0, 2, fastMA) < 2 ||
      CopyBuffer(hSlowMA, 0, 0, 2, slowMA) < 2 ||
      CopyBuffer(hRSI, 0, 0, 2, rsi) < 2) return 0;
   
   // Bullish crossover + RSI confirmation
   if(fastMA[1] <= slowMA[1] && fastMA[0] > slowMA[0] && rsi[0] < RSIOverbought)
      return 1;
      
   // Bearish crossover + RSI confirmation  
   if(fastMA[1] >= slowMA[1] && fastMA[0] < slowMA[0] && rsi[0] > RSIOversold)
      return -1;
   
   return 0;
}

//+------------------------------------------------------------------+
//| Open Hedging Pair (BUY + SELL)                                   |
//+------------------------------------------------------------------+
void OpenHedgingPair(ENUM_ORDER_TYPE direction)
{
   if(HasHedgingPair()) return;
   
   double lot = CalculateLotSize();
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slDistance = StopLossPips * pipSize;
   double tpDistance = TakeProfitPips * pipSize;
   
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   
   // Open first direction
   if(direction == ORDER_TYPE_BUY) {
      req.action = TRADE_ACTION_DEAL;
      req.symbol = _Symbol;
      req.volume = lot;
      req.type = ORDER_TYPE_BUY;
      req.price = ask;
      req.sl = ask - slDistance;
      req.tp = ask + tpDistance;
      req.deviation = SlippagePips * 10;
      req.magic = MagicNumber;
      req.comment = "Hedging BUY";
   } else {
      req.action = TRADE_ACTION_DEAL;
      req.symbol = _Symbol;
      req.volume = lot;
      req.type = ORDER_TYPE_SELL;
      req.price = bid;
      req.sl = bid + slDistance;
      req.tp = bid - tpDistance;
      req.deviation = SlippagePips * 10;
      req.magic = MagicNumber;
      req.comment = "Hedging SELL";
   }
   
   if(OrderSend(req, res)) {
      if(CountMyPositions() == 1) {  // Open opposite immediately
         ENUM_ORDER_TYPE opposite = (direction == ORDER_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         req.type = opposite;
         req.price = (opposite == ORDER_TYPE_BUY) ? ask : bid;
         req.sl = (opposite == ORDER_TYPE_BUY) ? ask - slDistance : bid + slDistance;
         req.tp = (opposite == ORDER_TYPE_BUY) ? ask + tpDistance : bid - tpDistance;
         req.comment = "Hedging OPPOSITE";
         OrderSend(req, res);
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate Lot Size based on Risk %                               |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * RiskPercent / 100.0;
   
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double slValue = StopLossPips * tickValue * pipSize / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   double lot = riskAmount / slValue;
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   lot = MathFloor(lot / stepLot) * stepLot;
   
   if(EnableMartingale && lastLotSize > 0) lot = MathMin(lot * MartingaleMultiplier, maxLot);
   
   lastLotSize = lot;
   return lot;
}

//+------------------------------------------------------------------+
//| Count Positions with Magic Number                                |
//+------------------------------------------------------------------+
int CountMyPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(position.SelectByIndex(i)) {
         if(position.Symbol() == _Symbol && position.Magic() == MagicNumber) count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Check if Hedging Pair exists                                     |
//+------------------------------------------------------------------+
bool HasHedgingPair()
{
   int buyCount = 0, sellCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(position.SelectByIndex(i)) {
         if(position.Symbol() == _Symbol && position.Magic() == MagicNumber) {
            if(position.PositionType() == POSITION_TYPE_BUY) buyCount++;
            else sellCount++;
         }
      }
   }
   return (buyCount > 0 && sellCount > 0);
}

//+------------------------------------------------------------------+
//| Trailing Stop for all positions                                  |
//+------------------------------------------------------------------+
void TrailingPositions()
{
   double trailDistance = TrailingDistancePips * pipSize;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(position.SelectByIndex(i) && position.Symbol() == _Symbol && position.Magic() == MagicNumber) {
         if(position.PositionType() == POSITION_TYPE_BUY) {
            double newSL = bid - trailDistance;
            if(newSL > position.StopLoss() + pipSize) {
               trade.PositionModify(position.Ticket(), newSL, position.TakeProfit());
            }
         } else {
            double newSL = ask + trailDistance;
            if(newSL < position.StopLoss() - pipSize || position.StopLoss() == 0) {
               trade.PositionModify(position.Ticket(), newSL, position.TakeProfit());
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Close Profitable Positions (>2-5 pips)                           |
//+------------------------------------------------------------------+
void ManageProfitablePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(position.SelectByIndex(i) && position.Symbol() == _Symbol && position.Magic() == MagicNumber) {
         double profitPips = (position.PositionType() == POSITION_TYPE_BUY) ? 
                            (SymbolInfoDouble(_Symbol, SYMBOL_BID) - position.PriceOpen()) / pipSize :
                            (position.PriceOpen() - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / pipSize;
         
         if(profitPips >= 3.0) {  // Close at 3+ pips profit
            trade.PositionClose(position.Ticket());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check Daily Loss Limit                                           |
//+------------------------------------------------------------------+
bool CheckDailyLoss()
{
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyLossPercent = (dailyStartEquity - currentEquity) / dailyStartEquity * 100.0;
   
   if(dailyLossPercent > MaxDailyLossPercent) {
      CloseAllPositions();
      Print("Daily loss limit reached: ", DoubleToString(dailyLossPercent, 2), "%");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Time Filter                                                      |
//+------------------------------------------------------------------+
bool IsTradeTime()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.hour >= StartHour && dt.hour <= EndHour);
}

//+------------------------------------------------------------------+
//| Close All Positions                                              |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(position.SelectByIndex(i) && position.Symbol() == _Symbol && position.Magic() == MagicNumber) {
         trade.PositionClose(position.Ticket());
      }
   }
}

//+------------------------------------------------------------------+
//| Update Dashboard                                                 |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   int positions = CountMyPositions();
   double dailyPnL = (equity - dailyStartEquity) / dailyStartEquity * 100.0;
   
   string dashboard = StringFormat(
      "=== Hedging Scalping XAUUSD ===
"
      "Balance: $%.2f | Equity: $%.2f
"
      "Daily P&L: %.2f%%
"
      "Open Positions: %d/%d
"
      "Spread: %d pips
"
      "Last Lot: %.2f",
      balance, equity, dailyPnL, positions, MaxOpenPositions,
      (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)/10,
      lastLotSize
   );
   Comment(dashboard);
}