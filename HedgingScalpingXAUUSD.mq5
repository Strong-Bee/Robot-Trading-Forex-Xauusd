//+------------------------------------------------------------------+
//| Expert Advisor: Hedging Scalping Robot XAUUSD                   |
//| Strategi: MA Crossover + RSI + Hedging                          |
//| Minimum Modal: $10 (risk-based lot)                             |
//+------------------------------------------------------------------+
#property copyright "Your Name"
#property version   "1.0"
#property strict

#include <TradeTrade.mqh>

//--- Input Parameters
// Strategi Parameters
input double initialBalance        = 10;      // Saldo awal (hanya referensi)
input int    FastMA                = 9;       // Period SMA cepat
input int    SlowMA                = 21;      // Period SMA lambat
input int    RSIPeriod             = 14;      // Period RSI
input int    RSIOverbought         = 70;      // Level overbought
input int    RSIOversold           = 30;      // Level oversold

// Risk Management
input double riskPercent           = 1.0;     // Risk per trade (% dari equity)
input int    stopLoss              = 50;      // SL dalam pips
input int    takeProfit            = 10;      // TP dalam pips
input double maxDailyLossPercent   = 5.0;     // Max loss per hari (%)

// Hedging Scalping
input int    hedgingSpread         = 3;       // Target spread / gap profit (pips)
input bool   enableTrailingStop    = true;    // Enable trailing stop
input int    trailingStopDistance  = 8;       // Trailing stop (pips)

// Position Management
input int    maxOpenPositions      = 4;       // Max posisi terbuka
input bool   enableMartingale      = false;   // Enable martingale (berisiko)
input double martingaleMultiplier  = 1.5;     // Lot multiplier after loss

// Time Filter
input bool   enableTimeFilter      = false;   // Filter jam trading
input int    startHour             = 14;      // Jam mulai (server time)
input int    endHour               = 22;      // Jam selesai (server time)

// General
input int    magicNumber           = 123456;  // Magic number
input int    slippage              = 10;      // Slippage (points)
input bool   enableLotSize         = true;    // Auto lot sizing

//--- Globals
CTrade  trade;
double  dailyStartBalance = 0.0;
datetime dailyDate        = 0;
int     totalOrdersToday  = 0;

// Statistik sederhana (bisa dikembangkan untuk winrate/profit factor)
int     winsToday         = 0;
int     lossesToday       = 0;

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   // Validasi symbol (opsional: bisa dihilangkan kalau ingin multi-symbol)
   if(_Symbol != "XAUUSD")
   {
      Alert("Robot ini didesain untuk XAUUSD, pastikan chart XAUUSD!");
      // Tidak di-Fail, karena beberapa broker pakai nama berbeda (XAUUSD.m dsb)
   }

   trade.SetExpertMagicNumber(magicNumber);

   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyDate         = TimeCurrent();

   Print("Hedging Scalping XAUUSD initialized. Balance: ", DoubleToString(dailyStartBalance, 2));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
   Print("Robot stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   // Reset hari baru
   if(TimeDay(dailyDate) != TimeDay(TimeCurrent()))
   {
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyDate         = TimeCurrent();
      totalOrdersToday  = 0;
      winsToday         = 0;
      lossesToday       = 0;
   }

   // Cek batas loss harian
   if(!CheckDailyLossLimit())
   {
      UpdateChartComments();
      return;
   }

   // Cek time filter
   if(enableTimeFilter && !IsTimeToTrade())
   {
      UpdateChartComments();
      return;
   }

   // Batas posisi terbuka
   if(CountOurPositions() >= maxOpenPositions)
   {
      UpdateChartComments();
      return;
   }

   // Trailing stop untuk posisi yang sudah profit
   if(enableTrailingStop)
      ApplyTrailingStop();

   // Kelola close profit berdasarkan target spread/gap
   ManageHedgingExits();

   // Cari sinyal entry
   int signal = GetTradingSignal();
   if(signal > 0)
      TryOpenHedgingPair(ORDER_TYPE_BUY);
   else if(signal < 0)
      TryOpenHedgingPair(ORDER_TYPE_SELL);

   UpdateChartComments();
}

//+------------------------------------------------------------------+
//| GetTradingSignal                                                 |
//+------------------------------------------------------------------+
int GetTradingSignal()
{
   // Gunakan harga close candle 1 (konfirmasi bar terakhir tutup)
   int shift = 1;

   double fastPrev = iMA(_Symbol, PERIOD_CURRENT, FastMA, 0, MODE_SMA, PRICE_CLOSE, shift+1);
   double slowPrev = iMA(_Symbol, PERIOD_CURRENT, SlowMA, 0, MODE_SMA, PRICE_CLOSE, shift+1);
   double fastCurr = iMA(_Symbol, PERIOD_CURRENT, FastMA, 0, MODE_SMA, PRICE_CLOSE, shift);
   double slowCurr = iMA(_Symbol, PERIOD_CURRENT, SlowMA, 0, MODE_SMA, PRICE_CLOSE, shift);

   if(fastPrev == 0.0 || slowPrev == 0.0 || fastCurr == 0.0 || slowCurr == 0.0)
      return 0;

   // RSI dari candle konfirmasi
   double rsi = iRSI(_Symbol, PERIOD_CURRENT, RSIPeriod, PRICE_CLOSE, shift);
   if(rsi <= 0.0)
      return 0;

   // BUY: fast MA cross up slow MA + RSI tidak overbought
   if(fastPrev <= slowPrev && fastCurr > slowCurr && rsi < RSIOverbought)
      return 1;

   // SELL: fast MA cross down slow MA + RSI tidak oversold
   if(fastPrev >= slowPrev && fastCurr < slowCurr && rsi > RSIOversold)
      return -1;

   return 0;
}

//+------------------------------------------------------------------+
//| TryOpenHedgingPair                                               |
//+------------------------------------------------------------------+
void TryOpenHedgingPair(ENUM_ORDER_TYPE entryType)
{
   // Pastikan belum ada pasangan hedge (BUY & SELL aktif)
   if(HaveHedgingPair())
      return;

   double lot = CalculateLotSize();
   if(lot <= 0.0)
   {
      Print("Lot size invalid, tidak membuka posisi.");
      return;
   }

   // Optional martingale sederhana: jika trade terakhir loss, kalikan lot
   if(enableMartingale)
      lot = AdjustLotMartingale(lot);

   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point= _Point;

   // Konversi SL/TP dari pips ke points
   double slPoints = stopLoss   * point;
   double tpPoints = takeProfit * point;

   bool buyRes=false, sellRes=false;

   // Buka dua posisi (BUY & SELL) dengan lot yang sama
   // EntryType hanya menentukan sisi utama, tapi tetap hedging dua arah
   // BUY
   double buySL = ask - slPoints;
   double buyTP = ask + tpPoints;
   trade.SetDeviationInPoints(slippage);
   buyRes = trade.Buy(lot, _Symbol, ask, buySL, buyTP, "Hedge BUY");

   // SELL
   double sellSL = bid + slPoints;
   double sellTP = bid - tpPoints;
   trade.SetDeviationInPoints(slippage);
   sellRes = trade.Sell(lot, _Symbol, bid, sellSL, sellTP, "Hedge SELL");

   if(buyRes || sellRes)
   {
      totalOrdersToday++;
      Print("Hedging pair opened. Lot: ", DoubleToString(lot, 2),
            " BUY=", buyRes, " SELL=", sellRes);
   }
}

//+------------------------------------------------------------------+
//| CalculateLotSize                                                 |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
   if(!enableLotSize)
      return NormalizeLot(0.01);

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmt   = equity * (riskPercent / 100.0);
   double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickVal <= 0.0 || tickSize <= 0.0 || stopLoss <= 0)
      return NormalizeLot(0.01);

   // Nilai 1 pip (umum: 1 pip = 10 * tick untuk 3-digit gold, cek broker)
   double pipSize   = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0;
   double pipValue  = tickVal * (pipSize / tickSize);

   if(pipValue <= 0.0)
      return NormalizeLot(0.01);

   // lot = riskAmount / (SL_pips * pipValue)
   double lot = riskAmt / (stopLoss * pipValue);

   // Pastikan minimum dan normalisasi ke step broker
   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
//| NormalizeLot                                                     |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   lot = MathFloor(lot / step) * step;

   return lot;
}

//+------------------------------------------------------------------+
//| AdjustLotMartingale                                              |
//+------------------------------------------------------------------+
double AdjustLotMartingale(double baseLot)
{
   // Cari trade terakhir kita di history; jika loss, kalikan lot
   ulong lastTicket = GetLastOurDealTicket();
   if(lastTicket == 0)
      return baseLot;

   if(HistorySelect(TimeCurrent() - 30*DAY, TimeCurrent()))
   {
      if(HistoryDealSelect(lastTicket))
      {
         double profit = HistoryDealGetDouble(lastTicket, DEAL_PROFIT);
         if(profit < 0.0)
         {
            double newLot = baseLot * martingaleMultiplier;
            return NormalizeLot(newLot);
         }
      }
   }

   return baseLot;
}

//+------------------------------------------------------------------+
//| GetLastOurDealTicket                                             |
//+------------------------------------------------------------------+
ulong GetLastOurDealTicket()
{
   if(!HistorySelect(TimeCurrent() - 30*DAY, TimeCurrent()))
      return 0;

   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(HistoryDealSelect(dealTicket))
      {
         long magic = (long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
         string sym = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
         if(magic == magicNumber && sym == _Symbol)
            return dealTicket;
      }
   }
   return 0;
}

//+------------------------------------------------------------------+
//| CountOurPositions                                                |
//+------------------------------------------------------------------+
int CountOurPositions()
{
   int cnt = 0;
   int total = PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i); // otomatis select posisi ini[web:10][web:15]
      if(ticket == 0)
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long   mgc = (long)PositionGetInteger(POSITION_MAGIC);

      if(sym == _Symbol && mgc == magicNumber)
         cnt++;
   }
   return cnt;
}

//+------------------------------------------------------------------+
//| HaveHedgingPair (BUY & SELL)                                     |
//+------------------------------------------------------------------+
bool HaveHedgingPair()
{
   bool hasBuy = false;
   bool hasSell= false;
   int total = PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long   mgc = (long)PositionGetInteger(POSITION_MAGIC);
      if(sym != _Symbol || mgc != magicNumber)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY)  hasBuy = true;
      if(type == POSITION_TYPE_SELL) hasSell = true;
   }
   return (hasBuy && hasSell);
}

//+------------------------------------------------------------------+
//| ManageHedgingExits                                               |
//+------------------------------------------------------------------+
void ManageHedgingExits()
{
   // Logika sederhana: jika total profit pair > target kecil, close kedua sisi
   double totalProfit = 0.0;
   int    total = PositionsTotal();

   // Hitung profit semua posisi EA di simbol ini
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long   mgc = (long)PositionGetInteger(POSITION_MAGIC);
      if(sym != _Symbol || mgc != magicNumber)
         continue;

      double pr = PositionGetDouble(POSITION_PROFIT);
      totalProfit += pr;
   }

   // Target profit kecil berdasarkan hedgingSpread (di-approx dalam dolar)
   // Misal 1 pip ~ $0.10 untuk lot kecil; Anda bisa kalibrasi manual saat forward test.
   double targetProfit = hedgingSpread; // asumsikan 1 = $1, silakan tweak

   if(totalProfit >= targetProfit && totalProfit > 0.0)
   {
      // Close semua posisi EA di simbol ini
      CloseAllOurPositions(true, totalProfit);
   }
}

//+------------------------------------------------------------------+
//| ApplyTrailingStop                                                |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
{
   double point   = _Point;
   double trailPt = trailingStopDistance * point;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long   mgc = (long)PositionGetInteger(POSITION_MAGIC);
      if(sym != _Symbol || mgc != magicNumber)
         continue;

      long   type       = PositionGetInteger(POSITION_TYPE);
      double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl         = PositionGetDouble(POSITION_SL);
      double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(type == POSITION_TYPE_BUY)
      {
         double newSL = bid - trailPt;
         // Update hanya jika SL lama < newSL dan price > open + trail
         if(newSL > sl && bid - openPrice > trailPt)
            trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double newSL = ask + trailPt;
         if((sl == 0.0 || newSL < sl) && openPrice - ask > trailPt)
            trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
      }
   }
}

//+------------------------------------------------------------------+
//| CloseAllOurPositions                                             |
//+------------------------------------------------------------------+
void CloseAllOurPositions(bool countStats = false, double totalProfit = 0.0)
{
   int total = PositionsTotal();
   // iterate backward karena jumlah posisi bisa berubah saat close[web:15]
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long   mgc = (long)PositionGetInteger(POSITION_MAGIC);
      if(sym != _Symbol || mgc != magicNumber)
         continue;

      double pr = PositionGetDouble(POSITION_PROFIT);
      if(trade.PositionClose(ticket))
      {
         if(countStats)
         {
            if(pr >= 0.0) winsToday++; else lossesToday++;
         }
      }
   }

   if(countStats && totalProfit != 0.0)
      Print("All EA positions closed. Session profit: ", DoubleToString(totalProfit, 2));
}

//+------------------------------------------------------------------+
//| CheckDailyLossLimit                                              |
//+------------------------------------------------------------------+
bool CheckDailyLossLimit()
{
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyLoss      = dailyStartBalance - currentBalance;
   double maxLossAllowed = dailyStartBalance * (maxDailyLossPercent / 100.0);

   if(dailyLoss > maxLossAllowed)
   {
      Print("Daily loss limit reached. Trading stopped for today.");
      CloseAllOurPositions();
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| IsTimeToTrade                                                    |
//+------------------------------------------------------------------+
bool IsTimeToTrade()
{
   datetime now  = TimeCurrent();
   int      hour = TimeHour(now);

   if(startHour <= endHour)
      return (hour >= startHour && hour < endHour);
   else
      // kasus sesi melewati tengah malam
      return (hour >= startHour || hour < endHour);
}

//+------------------------------------------------------------------+
//| UpdateChartComments                                              |
//+------------------------------------------------------------------+
void UpdateChartComments()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance= AccountInfoDouble(ACCOUNT_BALANCE);
   double profit = equity - balance;

   double dailyChangePct = 0.0;
   if(dailyStartBalance > 0.0)
      dailyChangePct = (balance - dailyStartBalance) / dailyStartBalance * 100.0;

   int openOurPos = CountOurPositions();

   string comment =
      StringFormat("Hedging Scalping XAUUSD
Balance: %.2f | Equity: %.2f | Float: %.2f
",
                   balance, equity, profit) +
      StringFormat("Daily P/L: %.2f %% | Orders Today: %d
", dailyChangePct, totalOrdersToday) +
      StringFormat("Open Positions (EA): %d | Wins: %d | Losses: %d
",
                   openOurPos, winsToday, lossesToday);

   Comment(comment);
}