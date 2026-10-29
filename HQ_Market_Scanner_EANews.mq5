//+------------------------------------------------------------------+
//|                                        HQ_Market_Scanner_EA.mq5  |
//|  v3.10  SWING TRADING SCANNER  (US Stocks | Holding 2-3 Days)     |
//|                                                                  |
//|  Based on v3.00. ADDED in v3.10:                                 |
//|    1) Horizontal scroll (left / right) for the table columns     |
//|         - Shift + Mouse wheel, or the [<] [>] buttons            |
//|         - SYMBOL column is frozen, other columns scroll          |
//|    2) Multi-Timeframe TREND + BIAS columns appended after STATUS |
//|         7D (W1) | 1D | 1H | 30M | 15M | 1M                       |
//|                                                                  |
//|  TF TREND (per timeframe, closed bars, live price):              |
//|     BULL  EMA fast > EMA slow  AND price > EMA slow              |
//|     BEAR  EMA fast < EMA slow  AND price < EMA slow              |
//|     NEUT  otherwise                                              |
//|  TF BIAS  (short-term direction, per timeframe):                 |
//|     BUY   price > EMA fast  AND EMA fast rising                  |
//|     SELL  price < EMA fast  AND EMA fast falling                 |
//|     NEUT  otherwise                                              |
//|  The TF columns are informational only. They do NOT change       |
//|  SETUP / STATUS (those still use Daily only).                    |
//|                                                                  |
//|  Code layout                                                     |
//|    1. Inputs / globals                                           |
//|    2. DATA        : symbol list, % change                        |
//|    3. STRATEGY    : BuildDailyCtx / EvaluateSetup / transitions  |
//|                     + BuildTfCtx / EvalTf (multi-timeframe)      |
//|    4. UI          : Draw* functions (read SwRow only)            |
//|    5. EVENTS      : wheel, buttons, row click / double-click     |
//|                                                                  |
//|  READY never places an order. This EA never trades.              |
//+------------------------------------------------------------------+
#property copyright "HQ-OB MT5 Scanner"
#property version   "3.10"

//---------------------------------------------------------------- Enums
enum ENUM_OPEN_REF
  {
   OPEN_PREV_CLOSE, // เทียบราคาปิดเมื่อวาน (เหมือน TradingView)
   OPEN_DAILY,      // เปิดแท่งรายวัน (D1) ปัจจุบัน
   OPEN_WEEKLY,     // เปิดแท่งรายสัปดาห์ (W1) ปัจจุบัน
   OPEN_SESSION     // เปิดหลัง gap ล่าสุด
  };

enum ENUM_HQ_SORT
  {
   SORT_MARKET_WATCH,   // ตามลำดับใน Market Watch
   SORT_PCT_DESC,       // % มากไปน้อย
   SORT_ABS_PCT_DESC,   // |%| มากไปน้อย
   SORT_STATUS_FIRST    // READY > WAIT > WATCH > SKIP ...
  };

enum ENUM_SW_STATUS
  {
   ST_NO_SETUP = 0,
   ST_WATCH,
   ST_WAIT,
   ST_READY,
   ST_SKIP,
   ST_INVALIDATED,
   ST_NA              // ไม่มีข้อมูล / Benchmark (แสดง —)
  };

enum ENUM_SW_SETUP
  {
   SU_NONE = 0,
   SU_PULLBACK,
   SU_BREAKOUT,
   SU_NA
  };

#define TR_BULL  1
#define TR_NEUT  0
#define TR_BEAR  (-1)
#define TR_NA    9

// Multi-timeframe columns
#define N_TF         6
#define N_BASE_COLS  6                       // PRICE, %CHG, TREND 1D, SETUP, VOLUME, STATUS
#define N_COLS       (N_BASE_COLS + 2 * N_TF)
#define SYM_W        90                      // frozen SYMBOL column width
#define PANEL_W      640
#define VIEW_W       (PANEL_W - 16 - SYM_W)  // width of the horizontally scrollable area

//---------------------------------------------------------------- Inputs
input group "Scan Scope"
input bool   UseMarketWatchOnly          = true;

input group "% Change Reference"
input ENUM_OPEN_REF OpenReference        = OPEN_PREV_CLOSE;
input int    SessionGapHours             = 2;

input group "Daily Trend / Indicators"
input int    TrendFastEMA                = 20;
input int    TrendSlowEMA                = 50;
input int    AtrLength                   = 14;
input int    VolAvgDays                  = 20;    // ค่าเฉลี่ย Volume สำหรับ Relative Volume
input int    BreakoutLookback            = 20;    // จำนวนแท่ง D1 (ปิดแล้ว) หา High
input int    DailyBars                   = 120;   // จำนวนแท่ง D1 ที่ดึงมาคำนวณ

input group "Multi-Timeframe Trend / Bias (7D 1D 1H 30M 15M 1M)"
input int    TfBars                      = 120;   // จำนวนแท่งต่อ TF ที่ดึงมาคำนวณ EMA (ต้องมากกว่า Slow EMA + 5)

input group "Setup Rules"
input double ApproachATR                 = 0.5;   // Breakout: ใกล้ level ภายในกี่ ATR = WATCH
input double MinRelVol                   = 1.0;   // Breakout: RelVol ขั้นต่ำเพื่อ READY
input double PullbackMinDepthATR         = 1.0;   // Pullback: ย่อจาก High อย่างน้อยกี่ ATR
input double PullbackZoneATR             = 0.5;   // Pullback: โซนรอบ EMA เร็ว (±ATR)
input double PullbackWatchATR            = 1.5;   // Pullback: อยู่เหนือ EMA เร็วไม่เกินกี่ ATR = WATCH

input group "Risk Filter (SKIP)"
input double BrkStopATR                  = 1.0;   // Breakout: Stop = level - x ATR
input double BrkTargetATR                = 3.0;   // Breakout: Target = entry + x ATR
input double MinRR                       = 1.5;
input double MaxRiskPct                  = 8.0;   // ระยะ Stop สูงสุด % ของราคา

input group "Benchmarks (OTHER section)"
input string BenchmarkSymbols            = "SPY;QQQ;HEQQ";
input bool   ShowNonUsInOther            = true;  // แสดง symbol ที่ไม่ใช่ US (ที่ไม่ใช่ Benchmark) ในกรอบ OTHER ด้วย

input group "Dashboard"
input bool   ShowAllSymbols              = true;  // false = เฉพาะ US ที่มี Setup (Benchmark แสดงเสมอ)
input ENUM_HQ_SORT SortMode              = SORT_PCT_DESC;
input int    ViewRowsUS                  = 12;    // จำนวนแถวสูงสุดที่เห็นในกรอบ US (เกินนี้เลื่อนได้)
input int    ViewRowsOther               = 6;
input int    WheelStep                   = 3;     // เลื่อนแนวตั้งต่อ 1 notch (แถว)
input int    HColStep                    = 1;     // เลื่อนแนวนอนต่อ 1 notch / 1 คลิกปุ่ม (คอลัมน์)
input color  FrameColor                  = C'0,170,255';
input string FontName                    = "Consolas";
input int    RefreshSeconds              = 10;
input int    DashX                       = 15;
input int    DashY                       = 25;

input group "US Stock Classification"
input string UsKeywords                  = "US;USA;NASDAQ;NYSE;AMEX;ARCA;BATS;XNAS;XNYS;UNITED STATES";
input bool   RequireStockInPath          = true;

//---------------------------------------------------------------- Types
struct DailyCtx
  {
   bool     ok;
   datetime bar;        // เวลาแท่ง D1 ปัจจุบันตอนคำนวณ
   double   emaF, emaS, atr, avgVol, hh, ll3, prevClose;
  };

struct TfCtx
  {
   bool     ok;
   datetime bar;        // เวลาแท่งปัจจุบันของ TF นั้นตอนคำนวณ
   double   emaF, emaS, emaFprev;
  };

struct SwRow
  {
   string   symbol;
   int      digits;
   bool     us, bench;
   bool     pctValid;
   double   price, pct;
   int      trend;      // TR_*
   int      setup;      // ENUM_SW_SETUP
   double   relVol;     // < 0 = ไม่มีข้อมูล
   int      status;     // ENUM_SW_STATUS
   // multi-timeframe (index = g_tfs order: 7D,1D,1H,30M,15M,1M)
   int      tfTrend[N_TF];   // TR_*
   int      tfBias[N_TF];    // TR_BULL = BUY, TR_BEAR = SELL, TR_NEUT, TR_NA
   // trade plan (analysis only)
   bool     planOk;
   double   entry, stop, target, rr, riskPct;
   double   emaF, emaS, atr, level;
  };

//---------------------------------------------------------------- Globals
string     PFX = "SWSC_";
#define ROW_H   16

const ENUM_TIMEFRAMES g_tfs[N_TF]   = {PERIOD_W1, PERIOD_D1, PERIOD_H1, PERIOD_M30, PERIOD_M15, PERIOD_M1};
const string          g_tfLbl[N_TF] = {"7D", "1D", "1H", "30M", "15M", "1M"};

string     g_symbols[];
bool       g_isUs[], g_isBench[], g_show[];
DailyCtx   g_ctx[];
TfCtx      g_tf[];          // size = symbols * N_TF
int        g_prevSt[];
datetime   g_invBar[];
string     g_usKw[], g_bench[];

SwRow      g_us[], g_ot[];
int        g_scrUs = 0, g_scrOt = 0;
int        g_colScr = 0, g_colMax = 0, g_colFirst = 0, g_colLast = N_BASE_COLS;
bool       g_origMouseScroll = true, g_origEvMove = false, g_origEvWheel = true;
bool       g_inside = false;
int        g_found = 0;
int        g_usTop = 0, g_usBot = 0, g_otTop = 0, g_otBot = 0;
int        g_usRow0 = 0, g_otRow0 = 0, g_viewUS = 1, g_viewOT = 1;

string     g_sel = "";
bool       g_detail = false;
string     g_lastClickSym = "";
ulong      g_lastClickMs = 0;

color C_BG     = C'5,5,5';
color C_HDR    = C'215,215,215';
color C_MUTED  = C'125,125,125';
color C_GREEN  = C'0,230,90';
color C_RED    = C'255,60,60';
color C_YELLOW = C'255,215,0';
color C_SELBG  = C'18,40,62';

//+------------------------------------------------------------------+
//| COLUMN LAYOUT (scrollable columns; SYMBOL is frozen)             |
//|   0 PRICE  1 %CHG  2 TREND 1D  3 SETUP  4 VOLUME  5 STATUS       |
//|   6.. : for each TF -> TREND, BIAS                               |
//+------------------------------------------------------------------+
int ColW(const int c)
  {
   switch(c)
     {
      case 0: return 80;   // PRICE
      case 1: return 80;   // % CHG
      case 2: return 90;   // TREND 1D
      case 3: return 90;   // SETUP
      case 4: return 70;   // VOLUME
      case 5: return 105;  // STATUS
     }
   return (((c - N_BASE_COLS) % 2) == 0) ? 84 : 76;   // TF TREND / TF BIAS
  }

bool ColRight(const int c)
  {
   return (c == 0 || c == 1 || c == 4);
  }

string ColHdr(const int c)
  {
   switch(c)
     {
      case 0: return "PRICE";
      case 1: return "% CHG";
      case 2: return "TREND 1D";
      case 3: return "SETUP";
      case 4: return "VOLUME";
      case 5: return "STATUS";
     }
   int t = (c - N_BASE_COLS) / 2;
   bool isBias = (((c - N_BASE_COLS) % 2) == 1);
   return g_tfLbl[t] + (isBias ? " BIAS" : " TREND");
  }

//--- last visible column (exclusive) when the view starts at 'first'
int VisibleLast(const int first)
  {
   int w = 0, c = first;
   while(c < N_COLS && w + ColW(c) <= VIEW_W)
     {
      w += ColW(c);
      c++;
     }
   return c;
  }

//--- max first-column index so that the last column is still visible
int MaxColScr()
  {
   for(int s = 0; s < N_COLS; s++)
      if(VisibleLast(s) >= N_COLS) return s;
   return 0;
  }

//+------------------------------------------------------------------+
//| 1. INIT / EVENTS                                                 |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_origMouseScroll = (bool)ChartGetInteger(0, CHART_MOUSE_SCROLL);
   g_origEvMove      = (bool)ChartGetInteger(0, CHART_EVENT_MOUSE_MOVE);
   g_origEvWheel     = (bool)ChartGetInteger(0, CHART_EVENT_MOUSE_WHEEL);
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
   ChartSetInteger(0, CHART_EVENT_MOUSE_WHEEL, true);

   BuildSymbolList();
   EventSetTimer(MathMax(1, RefreshSeconds));
   ScanAndDraw();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ChartSetInteger(0, CHART_MOUSE_SCROLL, g_origMouseScroll);
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, g_origEvMove);
   ChartSetInteger(0, CHART_EVENT_MOUSE_WHEEL, g_origEvWheel);
   ObjectsDeleteAll(0, PFX);
  }

void OnTick() {}
void OnTimer() { ScanAndDraw(); }

//--- group under the mouse: 1 = US, 2 = OTHER, 0 = none
int GroupAt(const int x, const int y)
  {
   int xl = DashX - 8;
   int xr = xl + PANEL_W;
   if(x < xl || x > xr) return 0;
   if(y >= g_usTop && y <= g_usBot) return 1;
   if(y >= g_otTop && y <= g_otBot) return 2;
   return 0;
  }

void SetInside(const bool inside)
  {
   if(inside == g_inside) return;
   g_inside = inside;
   ChartSetInteger(0, CHART_MOUSE_SCROLL, inside ? false : g_origMouseScroll);
  }

void ScrollGroup(const int group, const int deltaRows)
  {
   if(group == 1) g_scrUs += deltaRows;
   else if(group == 2) g_scrOt += deltaRows;
   DrawDashboard();
  }

//--- horizontal scroll (shared by both sections). delta > 0 = right
void ScrollCols(const int deltaCols)
  {
   g_colScr += deltaCols;
   DrawDashboard();   // clamped inside DrawDashboard
  }

//--- Click selects a row only. Double-click toggles the detail panel. NEVER sends orders.
void HandleClick(const int x, const int y)
  {
   int g = GroupAt(x, y);
   if(g == 0) return;

   int row0  = (g == 1) ? g_usRow0 : g_otRow0;
   int view  = (g == 1) ? g_viewUS : g_viewOT;
   int scr   = (g == 1) ? g_scrUs  : g_scrOt;
   int count = (g == 1) ? ArraySize(g_us) : ArraySize(g_ot);

   if(y < row0) return;
   int off = (y - row0) / ROW_H;
   if(off >= view) return;
   int idx = scr + off;
   if(idx >= count) return;

   string sym = (g == 1) ? g_us[idx].symbol : g_ot[idx].symbol;
   ulong  now = GetTickCount64();
   bool   dbl = (sym == g_lastClickSym && (now - g_lastClickMs) < 400);

   g_sel = sym;
   g_lastClickSym = sym;
   g_lastClickMs  = now;
   if(dbl) g_detail = !g_detail;
   DrawDashboard();
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_MOUSE_MOVE)
     {
      SetInside(GroupAt((int)lparam, (int)dparam) > 0);
      return;
     }

   if(id == CHARTEVENT_MOUSE_WHEEL)
     {
      int x     = (int)(short)lparam;
      int y     = (int)(short)(lparam >> 16);
      int flags = (int)((lparam >> 32) & 0xFFFF);
      int g = GroupAt(x, y);
      SetInside(g > 0);
      if(g > 0)
        {
         if((flags & 0x0004) != 0)   // Shift held -> horizontal scroll
            ScrollCols((dparam < 0) ? HColStep : -HColStep);
         else
            ScrollGroup(g, (dparam < 0) ? WheelStep : -WheelStep);
        }
      return;
     }

   if(id == CHARTEVENT_CLICK)
     {
      HandleClick((int)lparam, (int)dparam);
      return;
     }

   if(id == CHARTEVENT_OBJECT_CLICK)
     {
      if(StringFind(sparam, PFX + "btn_") != 0) return;
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);

      if(sparam == PFX + "btn_us_up")      ScrollGroup(1, -WheelStep);
      else if(sparam == PFX + "btn_us_dn") ScrollGroup(1,  WheelStep);
      else if(sparam == PFX + "btn_ot_up") ScrollGroup(2, -WheelStep);
      else if(sparam == PFX + "btn_ot_dn") ScrollGroup(2,  WheelStep);
      else if(sparam == PFX + "btn_us_lf" || sparam == PFX + "btn_ot_lf") ScrollCols(-HColStep);
      else if(sparam == PFX + "btn_us_rt" || sparam == PFX + "btn_ot_rt") ScrollCols( HColStep);
     }
  }

//+------------------------------------------------------------------+
//| 2. DATA                                                          |
//+------------------------------------------------------------------+
void ParseList(const string src, string &out[])
  {
   string parts[];
   int np = StringSplit(src, ';', parts);
   ArrayResize(out, 0);
   for(int p = 0; p < np; p++)
     {
      string kw = parts[p];
      StringTrimLeft(kw);
      StringTrimRight(kw);
      StringToUpper(kw);
      if(kw == "") continue;
      int n = ArraySize(out);
      ArrayResize(out, n + 1);
      out[n] = kw;
     }
  }

bool IsBenchmark(const string sym)
  {
   string full = sym;
   StringToUpper(full);
   int cut = StringLen(full);
   string seps = ".#_-";
   for(int s = 0; s < StringLen(seps); s++)
     {
      int pos = StringFind(full, StringSubstr(seps, s, 1));
      if(pos > 0 && pos < cut) cut = pos;
     }
   string base = StringSubstr(full, 0, cut);
   for(int k = 0; k < ArraySize(g_bench); k++)
      if(full == g_bench[k] || base == g_bench[k]) return true;
   return false;
  }

void BuildSymbolList()
  {
   int total = SymbolsTotal(UseMarketWatchOnly);
   ArrayResize(g_symbols, total);
   ArrayResize(g_isUs, total);
   ArrayResize(g_isBench, total);
   ArrayResize(g_show, total);
   ArrayResize(g_ctx, total);
   ArrayResize(g_tf, total * N_TF);
   ArrayResize(g_prevSt, total);
   ArrayResize(g_invBar, total);

   ParseList(UsKeywords, g_usKw);
   ParseList(BenchmarkSymbols, g_bench);

   for(int k = 0; k < total * N_TF; k++)
     {
      g_tf[k].ok  = false;
      g_tf[k].bar = 0;
     }

   int usCount = 0, bnCount = 0;
   for(int i = 0; i < total; i++)
     {
      g_symbols[i]  = SymbolName(i, UseMarketWatchOnly);
      g_isBench[i]  = IsBenchmark(g_symbols[i]);
      g_isUs[i]     = !g_isBench[i] && IsUsStock(g_symbols[i]);
      g_show[i]     = g_isUs[i] || g_isBench[i] || ShowNonUsInOther;
      g_ctx[i].ok   = false;
      g_ctx[i].bar  = 0;
      g_prevSt[i]   = ST_NO_SETUP;
      g_invBar[i]   = 0;
      if(g_isUs[i])    usCount++;
      if(g_isBench[i]) bnCount++;
     }
   PrintFormat("Swing Scanner: %d symbols, US stocks = %d, benchmarks = %d", total, usCount, bnCount);
  }

bool IsUsStock(const string sym)
  {
   string path = SymbolInfoString(sym, SYMBOL_PATH);
   string exch = SymbolInfoString(sym, SYMBOL_EXCHANGE);
   string cty  = SymbolInfoString(sym, SYMBOL_COUNTRY);
   StringToUpper(path);
   StringToUpper(exch);
   StringToUpper(cty);

   if(RequireStockInPath)
     {
      if(StringFind(path, "STOCK") < 0 && StringFind(path, "SHARE") < 0 && StringFind(path, "EQUIT") < 0)
         return false;
     }

   string seg[];
   int ns = StringSplit(path, '\\', seg);

   for(int k = 0; k < ArraySize(g_usKw); k++)
     {
      string kw = g_usKw[k];
      for(int s = 0; s < ns; s++)
         if(seg[s] == kw) return true;
      if(exch != "" && (exch == kw || StringFind(exch, kw) >= 0)) return true;
      if(cty  != "" && (cty  == kw || StringFind(cty,  kw) >= 0)) return true;
     }
   return false;
  }

void ResetRow(SwRow &r, const string sym)
  {
   r.symbol   = sym;
   r.digits   = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   r.us       = false;
   r.bench    = false;
   r.pctValid = false;
   r.price    = 0.0;
   r.pct      = 0.0;
   r.trend    = TR_NA;
   r.setup    = SU_NA;
   r.relVol   = -1.0;
   r.status   = ST_NA;
   r.planOk   = false;
   r.entry = r.stop = r.target = r.rr = r.riskPct = 0.0;
   r.emaF = r.emaS = r.atr = r.level = 0.0;
   for(int t = 0; t < N_TF; t++)
     {
      r.tfTrend[t] = TR_NA;
      r.tfBias[t]  = TR_NA;
     }
  }

double GetOpenPrice(const string sym)
  {
   if(OpenReference == OPEN_PREV_CLOSE)
     {
      double pc = iClose(sym, PERIOD_D1, 1);
      if(pc > 0.0) return pc;
      return iOpen(sym, PERIOD_D1, 0);
     }
   if(OpenReference == OPEN_DAILY)
      return iOpen(sym, PERIOD_D1, 0);
   if(OpenReference == OPEN_WEEKLY)
      return iOpen(sym, PERIOD_W1, 0);

   MqlRates h[];
   int n = CopyRates(sym, PERIOD_H1, 0, 300, h);
   if(n >= 2)
     {
      ArraySetAsSeries(h, false);
      long needDiff = (long)(SessionGapHours + 1) * 3600;
      for(int i = n - 1; i > 0; i--)
         if((long)(h[i].time - h[i-1].time) >= needDiff)
            return h[i].open;
     }
   return iOpen(sym, PERIOD_D1, 0);
  }

void CalcPctSinceOpen(SwRow &r)
  {
   double refP  = GetOpenPrice(r.symbol);
   double price = SymbolInfoDouble(r.symbol, SYMBOL_BID);
   if(price <= 0.0) price = SymbolInfoDouble(r.symbol, SYMBOL_LAST);
   if(price <= 0.0) price = iClose(r.symbol, PERIOD_M1, 0);

   if(refP > 0.0 && price > 0.0)
     {
      r.price    = price;
      r.pct      = (price - refP) / refP * 100.0;
      r.pctValid = true;
     }
  }

//+------------------------------------------------------------------+
//| 3. STRATEGY (no drawing code here)                               |
//+------------------------------------------------------------------+
double RateVol(const MqlRates &x)
  {
   return (x.real_volume > 0) ? (double)x.real_volume : (double)x.tick_volume;
  }

double EmaLast(const MqlRates &r[], const int n, const int period)
  {
   if(period < 1 || n < period) return 0.0;
   double sum = 0.0;
   for(int i = 0; i < period; i++) sum += r[i].close;
   double ema = sum / period;
   double k = 2.0 / (period + 1.0);
   for(int i = period; i < n; i++)
      ema = r[i].close * k + ema * (1.0 - k);
   return ema;
  }

double AtrLast(const MqlRates &r[], const int n, const int period)
  {
   if(period < 1 || n < period + 1) return 0.0;
   double sum = 0.0;
   for(int i = 1; i <= period; i++)
      sum += MathMax(r[i].high - r[i].low,
                     MathMax(MathAbs(r[i].high - r[i-1].close), MathAbs(r[i].low - r[i-1].close)));
   double atr = sum / period;
   for(int i = period + 1; i < n; i++)
     {
      double tr = MathMax(r[i].high - r[i].low,
                          MathMax(MathAbs(r[i].high - r[i-1].close), MathAbs(r[i].low - r[i-1].close)));
      atr = (atr * (period - 1) + tr) / period;
     }
   return atr;
  }

//--- indicators from CLOSED daily bars (recomputed once per new D1 bar)
bool BuildDailyCtx(const string sym, DailyCtx &c)
  {
   c.ok = false;
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(sym, PERIOD_D1, 1, MathMax(DailyBars, 30), r);
   int need = MathMax(TrendSlowEMA, MathMax(AtrLength, MathMax(VolAvgDays, BreakoutLookback))) + 5;
   if(n < need) return false;

   c.emaF = EmaLast(r, n, TrendFastEMA);
   c.emaS = EmaLast(r, n, TrendSlowEMA);
   c.atr  = AtrLast(r, n, AtrLength);
   if(c.emaF <= 0.0 || c.emaS <= 0.0 || c.atr <= 0.0) return false;

   double vs = 0.0;
   int vn = MathMin(VolAvgDays, n);
   for(int i = n - vn; i < n; i++) vs += RateVol(r[i]);
   c.avgVol = (vn > 0) ? vs / vn : 0.0;

   double hh = 0.0;
   int bn = MathMin(BreakoutLookback, n);
   for(int i = n - bn; i < n; i++) hh = MathMax(hh, r[i].high);
   c.hh = hh;

   double ll = r[n-1].low;
   for(int i = n - 3; i < n; i++) ll = MathMin(ll, r[i].low);
   c.ll3 = ll;

   c.prevClose = r[n-1].close;
   c.bar = iTime(sym, PERIOD_D1, 0);
   c.ok = true;
   return true;
  }

//--- EMA context for any timeframe, from CLOSED bars (recomputed once per new bar of that TF)
bool BuildTfCtx(const string sym, const ENUM_TIMEFRAMES tf, TfCtx &c)
  {
   c.ok = false;
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int want = MathMax(TfBars, TrendSlowEMA + 10);
   int n = CopyRates(sym, tf, 1, want, r);
   if(n < TrendSlowEMA + 5) return false;

   c.emaF     = EmaLast(r, n,     TrendFastEMA);
   c.emaS     = EmaLast(r, n,     TrendSlowEMA);
   c.emaFprev = EmaLast(r, n - 1, TrendFastEMA);
   if(c.emaF <= 0.0 || c.emaS <= 0.0 || c.emaFprev <= 0.0) return false;

   c.bar = iTime(sym, tf, 0);
   c.ok  = true;
   return true;
  }

//--- TREND = structure (fast vs slow EMA + price vs slow EMA)
//--- BIAS  = short-term direction (price vs fast EMA + fast EMA slope)
void EvalTf(const TfCtx &c, const double p, int &trend, int &bias)
  {
   if(c.emaF > c.emaS && p > c.emaS)      trend = TR_BULL;
   else if(c.emaF < c.emaS && p < c.emaS) trend = TR_BEAR;
   else                                   trend = TR_NEUT;

   if(p > c.emaF && c.emaF > c.emaFprev)      bias = TR_BULL;   // BUY
   else if(p < c.emaF && c.emaF < c.emaFprev) bias = TR_BEAR;   // SELL
   else                                       bias = TR_NEUT;
  }

//--- trend + setup + raw status + trade plan using live price
void EvaluateSetup(const DailyCtx &c, SwRow &w, const double todayOpen, const double todayLow)
  {
   double p = w.price, atr = c.atr;
   w.emaF = c.emaF; w.emaS = c.emaS; w.atr = atr; w.level = c.hh;

   if(c.emaF > c.emaS && p > c.emaS)      w.trend = TR_BULL;
   else if(c.emaF < c.emaS && p < c.emaS) w.trend = TR_BEAR;
   else                                   w.trend = TR_NEUT;

   w.setup  = SU_NONE;
   w.status = ST_NO_SETUP;
   if(w.trend != TR_BULL || atr <= 0.0) return;

   double level = c.hh;
   bool brk = (p >= level - ApproachATR * atr);
   bool pb  = (!brk && (level - p) >= PullbackMinDepthATR * atr && p <= c.emaF + PullbackWatchATR * atr);
   if(!brk && !pb) return;

   double entry, stop, target;
   if(brk)
     {
      w.setup = SU_BREAKOUT;
      entry   = MathMax(p, level);
      stop    = level - BrkStopATR * atr;
      target  = entry + BrkTargetATR * atr;

      if(p < level)                                   w.status = ST_WATCH;
      else if(w.relVol < 0.0 || w.relVol < MinRelVol) w.status = ST_WAIT;
      else                                            w.status = ST_READY;
     }
   else
     {
      w.setup = SU_PULLBACK;
      entry   = p;
      double lo = (todayLow > 0.0) ? MathMin(c.ll3, todayLow) : c.ll3;
      stop    = lo - 0.25 * atr;
      target  = level;

      if(p > c.emaF + PullbackZoneATR * atr)
         w.status = ST_WATCH;
      else
        {
         bool bounce = (p > todayOpen && todayOpen > 0.0 && todayLow >= c.emaS);
         w.status = bounce ? ST_READY : ST_WAIT;
        }
     }

   double risk   = entry - stop;
   double reward = target - entry;
   w.entry = entry; w.stop = stop; w.target = target;
   if(risk > 0.0 && entry > 0.0)
     {
      w.planOk  = true;
      w.rr      = (reward > 0.0) ? reward / risk : 0.0;
      w.riskPct = risk / entry * 100.0;
     }

   // Risk filter overrides WATCH / WAIT / READY
   if(!w.planOk || w.rr < MinRR || w.riskPct > MaxRiskPct)
      w.status = ST_SKIP;
  }

//--- INVALIDATED handling (setup disappeared after being active)
void ApplyTransition(const int i, SwRow &w, const datetime curBar)
  {
   int prev = g_prevSt[i];
   if(w.setup == SU_NONE)
     {
      if(prev == ST_WATCH || prev == ST_WAIT || prev == ST_READY)
        {
         w.status = ST_INVALIDATED;
         g_invBar[i] = curBar;
        }
      else if(prev == ST_INVALIDATED && g_invBar[i] == curBar)
         w.status = ST_INVALIDATED;
      else
         w.status = ST_NO_SETUP;
     }
   g_prevSt[i] = w.status;
  }

int StatusRank(const int s)
  {
   switch(s)
     {
      case ST_READY:       return 5;
      case ST_WAIT:        return 4;
      case ST_WATCH:       return 3;
      case ST_SKIP:        return 2;
      case ST_INVALIDATED: return 1;
     }
   return 0;
  }

bool ShouldSwap(const SwRow &a, const SwRow &b)
  {
   if(!a.pctValid && b.pctValid) return true;
   if(a.pctValid && !b.pctValid) return false;
   switch(SortMode)
     {
      case SORT_PCT_DESC:     return (b.pct > a.pct);
      case SORT_ABS_PCT_DESC: return (MathAbs(b.pct) > MathAbs(a.pct));
      case SORT_STATUS_FIRST:
        {
         int ra = StatusRank(a.status), rb = StatusRank(b.status);
         if(ra != rb) return (rb > ra);
         return (b.pct > a.pct);
        }
     }
   return false;
  }

void ScanAndDraw()
  {
   int total = ArraySize(g_symbols);
   SwRow results[];
   int found = 0;

   for(int i = 0; i < total; i++)
     {
      if(!g_show[i]) continue;

      SwRow w;
      ResetRow(w, g_symbols[i]);
      w.us    = g_isUs[i];
      w.bench = g_isBench[i];
      CalcPctSinceOpen(w);

      datetime d1 = iTime(g_symbols[i], PERIOD_D1, 0);
      if(!g_ctx[i].ok || g_ctx[i].bar != d1)
         BuildDailyCtx(g_symbols[i], g_ctx[i]);

      if(g_ctx[i].ok && w.pctValid)
        {
         MqlRates t[];
         double tOpen = 0.0, tLow = 0.0, tVol = 0.0;
         if(CopyRates(g_symbols[i], PERIOD_D1, 0, 1, t) == 1)
           {
            tOpen = t[0].open; tLow = t[0].low; tVol = RateVol(t[0]);
           }
         // NOTE: today's volume is partial intraday -> RelVol is understated early in the session
         w.relVol = (g_ctx[i].avgVol > 0.0 && tVol > 0.0) ? tVol / g_ctx[i].avgVol : -1.0;

         EvaluateSetup(g_ctx[i], w, tOpen, tLow);

         if(w.bench)
           {
            w.setup  = SU_NA;     // never fabricate signals for benchmarks
            w.status = ST_NA;
            w.planOk = false;
           }
         else
            ApplyTransition(i, w, d1);
        }

      // Multi-timeframe TREND / BIAS (informational only)
      if(w.pctValid)
        {
         for(int tf = 0; tf < N_TF; tf++)
           {
            int idx = i * N_TF + tf;
            datetime cur = iTime(g_symbols[i], g_tfs[tf], 0);
            if(!g_tf[idx].ok || g_tf[idx].bar != cur)
               BuildTfCtx(g_symbols[i], g_tfs[tf], g_tf[idx]);
            if(g_tf[idx].ok)
               EvalTf(g_tf[idx], w.price, w.tfTrend[tf], w.tfBias[tf]);
           }
        }

      if(!ShowAllSymbols && !w.bench && w.setup != SU_PULLBACK && w.setup != SU_BREAKOUT)
         continue;

      ArrayResize(results, found + 1);
      results[found] = w;
      found++;
     }

   if(SortMode != SORT_MARKET_WATCH)
     {
      for(int a = 0; a < found - 1; a++)
         for(int b = a + 1; b < found; b++)
            if(ShouldSwap(results[a], results[b]))
              {
               SwRow tmp = results[a]; results[a] = results[b]; results[b] = tmp;
              }
     }

   ArrayResize(g_us, 0);
   ArrayResize(g_ot, 0);
   for(int k = 0; k < found; k++)
     {
      if(results[k].us)
        {
         int n = ArraySize(g_us);
         ArrayResize(g_us, n + 1);
         g_us[n] = results[k];
        }
      else
        {
         int n = ArraySize(g_ot);
         ArrayResize(g_ot, n + 1);
         g_ot[n] = results[k];
        }
     }

   g_found = found;
   DrawDashboard();
  }

//+------------------------------------------------------------------+
//| 4. UI (reads SwRow only)                                         |
//+------------------------------------------------------------------+
string OpenRefText()
  {
   if(OpenReference == OPEN_PREV_CLOSE) return "Prev Close";
   if(OpenReference == OPEN_DAILY)      return "Daily Open";
   if(OpenReference == OPEN_WEEKLY)     return "Weekly Open";
   return "Session Open";
  }

string TrendTxt(const int t)
  {
   if(t == TR_BULL) return "BULLISH";
   if(t == TR_BEAR) return "BEARISH";
   if(t == TR_NEUT) return "NEUTRAL";
   return "—";
  }
color TrendClr(const int t)
  {
   if(t == TR_BULL) return C_GREEN;
   if(t == TR_BEAR) return C_RED;
   if(t == TR_NEUT) return C_HDR;
   return C_MUTED;
  }

//--- short forms for the TF columns
string TfTrendTxt(const int t)
  {
   if(t == TR_BULL) return "BULL";
   if(t == TR_BEAR) return "BEAR";
   if(t == TR_NEUT) return "NEUT";
   return "—";
  }
string TfBiasTxt(const int b)
  {
   if(b == TR_BULL) return "BUY";
   if(b == TR_BEAR) return "SELL";
   if(b == TR_NEUT) return "NEUT";
   return "—";
  }

string SetupTxt(const int s)
  {
   if(s == SU_PULLBACK) return "PULLBACK";
   if(s == SU_BREAKOUT) return "BREAKOUT";
   if(s == SU_NONE)     return "NONE";
   return "—";
  }
color SetupClr(const int s)
  {
   return (s == SU_PULLBACK || s == SU_BREAKOUT) ? C_HDR : C_MUTED;
  }
string StatusTxt(const int s)
  {
   switch(s)
     {
      case ST_NO_SETUP:    return "NO SETUP";
      case ST_WATCH:       return "WATCH";
      case ST_WAIT:        return "WAIT";
      case ST_READY:       return "READY";
      case ST_SKIP:        return "SKIP";
      case ST_INVALIDATED: return "INVALIDATED";
     }
   return "—";
  }
color StatusClr(const int s)
  {
   switch(s)
     {
      case ST_READY:                  return C_GREEN;
      case ST_WATCH: case ST_WAIT:    return C_YELLOW;
      case ST_SKIP: case ST_INVALIDATED: return C_RED;
     }
   return C_MUTED;
  }

string ShortSym(const string s)
  {
   return (StringLen(s) > 10) ? StringSubstr(s, 0, 9) + "~" : s;
  }

string Fmt(const double v, const int digits)
  {
   return DoubleToString(v, digits);
  }

//--- primitives
void SetLbl(const string name, const string text, const int x, const int y, const color clr,
            const int size, const bool bold, const ENUM_ANCHOR_POINT anchor = ANCHOR_LEFT_UPPER)
  {
   string full = PFX + name;
   if(ObjectFind(0, full) < 0) ObjectCreate(0, full, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, full, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, full, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, full, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, full, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, full, OBJPROP_TEXT, text);
   ObjectSetInteger(0, full, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, full, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, full, OBJPROP_FONT, bold ? FontName + " Bold" : FontName);
   ObjectSetInteger(0, full, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, full, OBJPROP_HIDDEN, true);
  }

void SetRect(const string name, const int x, const int y, const int w, const int h,
             const color bg, const color border)
  {
   string full = PFX + name;
   if(ObjectFind(0, full) < 0) ObjectCreate(0, full, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, full, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, full, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, full, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, full, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, full, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, full, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, full, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, full, OBJPROP_COLOR, border);
   ObjectSetInteger(0, full, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, full, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, full, OBJPROP_HIDDEN, true);
  }

void SetButton(const string name, const string text, const int x, const int y)
  {
   if(ObjectFind(0, name) < 0) ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, 22);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 15);
   ObjectSetString(0,  name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_COLOR, C_HDR);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'20,20,20');
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, FrameColor);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 10);
  }

//--- place a text inside a column cell (x = left edge of the cell)
void PlaceCell(const string name, const string text, const int x, const int w, const bool right,
               const int y, const color clr, const int size, const bool bold)
  {
   if(right) SetLbl(name, text, x + w - 10, y, clr, size, bold, ANCHOR_RIGHT_UPPER);
   else      SetLbl(name, text, x,          y, clr, size, bold, ANCHOR_LEFT_UPPER);
  }

//--- text + colour for one scrollable column of a row
void CellOf(const SwRow &r, const int c, string &txt, color &clr)
  {
   txt = "—";
   clr = C_MUTED;

   switch(c)
     {
      case 0:
         if(r.pctValid) { txt = Fmt(r.price, r.digits); clr = C_HDR; }
         else           { txt = "n/a"; }
         return;
      case 1:
         if(r.pctValid)
           {
            txt = (r.pct >= 0 ? "+" : "") + DoubleToString(r.pct, 2) + "%";
            clr = (r.pct > 0) ? C_GREEN : (r.pct < 0 ? C_RED : C_HDR);
           }
         else txt = "n/a";
         return;
      case 2:
         txt = TrendTxt(r.trend);   clr = TrendClr(r.trend);   return;
      case 3:
         txt = SetupTxt(r.setup);   clr = SetupClr(r.setup);   return;
      case 4:
         if(r.relVol >= 0.0) { txt = DoubleToString(r.relVol, 1) + "x"; clr = C_HDR; }
         return;
      case 5:
         txt = StatusTxt(r.status); clr = StatusClr(r.status); return;
     }

   int  t      = (c - N_BASE_COLS) / 2;
   bool isBias = (((c - N_BASE_COLS) % 2) == 1);
   if(isBias)
     {
      txt = TfBiasTxt(r.tfBias[t]);
      int b = r.tfBias[t];
      clr = (b == TR_BULL) ? C_GREEN : (b == TR_BEAR ? C_RED : (b == TR_NEUT ? C_HDR : C_MUTED));
     }
   else
     {
      txt = TfTrendTxt(r.tfTrend[t]);
      clr = TrendClr(r.tfTrend[t]);
     }
  }

void DrawRow(const string id, const SwRow &r, const int y)
  {
   const int F = 9;

   if(r.symbol == g_sel)
      SetRect("row_sel_" + id, DashX - 6, y - 1, PANEL_W - 4, ROW_H, C_SELBG, C_SELBG);

   // frozen column
   SetLbl("row_sym_" + id, ShortSym(r.symbol), DashX, y, C_HDR, F, false);

   // scrollable columns
   int x = DashX + SYM_W;
   for(int c = g_colFirst; c < g_colLast; c++)
     {
      string txt;
      color  clr;
      CellOf(r, c, txt, clr);
      PlaceCell("row_c" + IntegerToString(c) + "_" + id, txt, x, ColW(c), ColRight(c), y, clr, F, false);
      x += ColW(c);
     }
  }

int SectionHeight(const int view) { return 42 + view * ROW_H + 6; }

//--- draws one section, returns its bottom y
int DrawSection(const string tag, const string title, SwRow &arr[], const int count,
                int &scr, const int view, const int y0)
  {
   const int F = 9;
   int maxScr = MathMax(0, count - view);
   if(scr > maxScr) scr = maxScr;
   if(scr < 0)      scr = 0;

   SetRect("sep_" + tag, DashX - 8, y0, PANEL_W, 1, FrameColor, FrameColor);

   string rng = (count == 0) ? "0" :
                IntegerToString(scr + 1) + "-" + IntegerToString(MathMin(scr + view, count)) +
                " / " + IntegerToString(count);
   SetLbl("hdr_" + tag + "_title", title + "  [" + rng + "]", DashX, y0 + 5, FrameColor, 10, true);

   // vertical scroll buttons
   if(count > view)
     {
      SetButton(PFX + "btn_" + tag + "_up", "▲", DashX + PANEL_W - 62, y0 + 4);
      SetButton(PFX + "btn_" + tag + "_dn", "▼", DashX + PANEL_W - 36, y0 + 4);
     }
   else
     {
      ObjectDelete(0, PFX + "btn_" + tag + "_up");
      ObjectDelete(0, PFX + "btn_" + tag + "_dn");
     }

   // horizontal scroll buttons
   if(g_colMax > 0)
     {
      SetButton(PFX + "btn_" + tag + "_lf", "◄", DashX + PANEL_W - 114, y0 + 4);
      SetButton(PFX + "btn_" + tag + "_rt", "►", DashX + PANEL_W - 88,  y0 + 4);
     }
   else
     {
      ObjectDelete(0, PFX + "btn_" + tag + "_lf");
      ObjectDelete(0, PFX + "btn_" + tag + "_rt");
     }

   // header row: frozen SYMBOL + visible scrollable columns
   int hy = y0 + 24;
   SetLbl("hdr_" + tag + "_sym", "SYMBOL", DashX, hy, C_HDR, F, true);
   int hx = DashX + SYM_W;
   for(int c = g_colFirst; c < g_colLast; c++)
     {
      PlaceCell("hdr_" + tag + "_c" + IntegerToString(c), ColHdr(c), hx, ColW(c), ColRight(c), hy, C_HDR, F, true);
      hx += ColW(c);
     }
   SetRect("hdr_" + tag + "_ln", DashX - 6, y0 + 39, PANEL_W - 4, 1, C'45,45,45', C'45,45,45');

   int row0 = y0 + 42;
   if(count == 0)
     {
      SetLbl("row_" + tag + "_none", "-- no symbols in this group --", DashX, row0, C_MUTED, F, false);
      return y0 + SectionHeight(view);
     }

   int last = MathMin(scr + view, count);
   for(int i = scr; i < last; i++)
      DrawRow(tag + "_" + IntegerToString(i), arr[i], row0 + (i - scr) * ROW_H);

   return y0 + SectionHeight(view);
  }

bool FindRow(const string sym, SwRow &out)
  {
   for(int i = 0; i < ArraySize(g_us); i++)
      if(g_us[i].symbol == sym) { out = g_us[i]; return true; }
   for(int i = 0; i < ArraySize(g_ot); i++)
      if(g_ot[i].symbol == sym) { out = g_ot[i]; return true; }
   return false;
  }

//--- "7D BULL/BUY   1D BULL/SELL   1H NEUT/NEUT"
string TfLine(const SwRow &w, const int from, const int to)
  {
   string s = "";
   for(int t = from; t < to; t++)
     {
      if(t > from) s += "   ";
      s += g_tfLbl[t] + " " + TfTrendTxt(w.tfTrend[t]) + "/" + TfBiasTxt(w.tfBias[t]);
     }
   return s;
  }

//--- detail panel (analysis + trade plan only; no order logic)
int DrawDetail(const int y0)
  {
   const int F = 9;
   SwRow w;
   SetRect("sep_det", DashX - 8, y0, PANEL_W, 1, FrameColor, FrameColor);

   if(!FindRow(g_sel, w))
     {
      SetLbl("det_0", "No symbol selected", DashX, y0 + 6, C_MUTED, F, false);
      return y0 + 26;
     }

   int d = w.digits;
   SetLbl("det_0", "DETAIL  " + w.symbol + "   " + TrendTxt(w.trend) + "   " + SetupTxt(w.setup) +
          "   " + StatusTxt(w.status), DashX, y0 + 6, FrameColor, 10, true);

   if(w.trend == TR_NA)
     {
      SetLbl("det_1", "No daily data available yet", DashX, y0 + 26, C_MUTED, F, false);
      return y0 + 50;
     }

   SetLbl("det_1", "Price " + Fmt(w.price, d) + "   EMA" + IntegerToString(TrendFastEMA) + " " + Fmt(w.emaF, d) +
          "   EMA" + IntegerToString(TrendSlowEMA) + " " + Fmt(w.emaS, d) +
          "   ATR" + IntegerToString(AtrLength) + " " + Fmt(w.atr, d), DashX, y0 + 26, C_HDR, F, false);
   SetLbl("det_2", StringFormat("%d-day high %s   RelVol %s", BreakoutLookback, Fmt(w.level, d),
          (w.relVol >= 0.0 ? DoubleToString(w.relVol, 2) + "x" : "n/a")), DashX, y0 + 42, C_HDR, F, false);

   if(w.planOk)
      SetLbl("det_3", "Entry " + Fmt(w.entry, d) + "   Stop " + Fmt(w.stop, d) + "   Target " + Fmt(w.target, d) +
             "   R:R " + DoubleToString(w.rr, 2) + "   Risk " + DoubleToString(w.riskPct, 2) + "%",
             DashX, y0 + 58, C_YELLOW, F, false);
   else
      SetLbl("det_3", "Trade plan: n/a (no active setup)", DashX, y0 + 58, C_MUTED, F, false);

   SetLbl("det_tf1", "MTF (trend/bias)  " + TfLine(w, 0, 3), DashX, y0 + 74, C_HDR, F, false);
   SetLbl("det_tf2", "                  " + TfLine(w, 3, 6), DashX, y0 + 90, C_HDR, F, false);

   SetLbl("det_4", "Analysis only. This EA never sends orders.", DashX, y0 + 106, C_MUTED, 8, false);
   return y0 + 126;
  }

void DrawDashboard()
  {
   ObjectsDeleteAll(0, PFX + "row_");
   ObjectsDeleteAll(0, PFX + "hdr_");
   ObjectsDeleteAll(0, PFX + "det_");
   ObjectDelete(0, PFX + "sep_det");

   g_viewUS = MathMax(1, ViewRowsUS);
   g_viewOT = MathMax(1, ViewRowsOther);

   // horizontal scroll range + visible columns
   g_colMax = MaxColScr();
   if(g_colScr > g_colMax) g_colScr = g_colMax;
   if(g_colScr < 0)        g_colScr = 0;
   g_colFirst = g_colScr;
   g_colLast  = VisibleLast(g_colFirst);

   // title block
   SetLbl("hdr_title",    "SWING TRADING SCANNER", DashX, DashY, C_HDR, 12, true);
   SetLbl("hdr_subtitle", "US Stocks | Holding Period: 2–3 Days", DashX, DashY + 20, C_MUTED, 9, false);
   string colTxt = (g_colMax > 0)
                   ? " | cols " + IntegerToString(g_colFirst + 1) + "-" + IntegerToString(g_colLast) +
                     "/" + IntegerToString(N_COLS) + " (Shift+wheel)"
                   : "";
   SetLbl("hdr_stats", "% vs " + OpenRefText() + " | " + IntegerToString(g_found) + " sym" + colTxt,
          DashX + PANEL_W - 16, DashY + 4, C_MUTED, 8, false, ANCHOR_RIGHT_UPPER);

   g_usTop = DashY + 38;
   g_usBot = DashY + 38 + SectionHeight(g_viewUS);
   g_usRow0 = g_usTop + 42;
   g_otTop = g_usBot;
   g_otBot = g_otTop + SectionHeight(g_viewOT);
   g_otRow0 = g_otTop + 42;

   int bottom = DrawSection("us", "US STOCKS", g_us, ArraySize(g_us), g_scrUs, g_viewUS, g_usTop);
   bottom     = DrawSection("ot", "OTHER",     g_ot, ArraySize(g_ot), g_scrOt, g_viewOT, g_otTop);
   if(g_detail)
      bottom = DrawDetail(bottom);

   // outer frame (created first time -> stays below later objects)
   SetRect("frame", DashX - 8, DashY - 8, PANEL_W, bottom - (DashY - 8) + 2, C_BG, FrameColor);

   ChartRedraw();
  }
//+------------------------------------------------------------------+