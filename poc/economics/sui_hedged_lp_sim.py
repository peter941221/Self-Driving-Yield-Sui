#!/usr/bin/env python3
"""
Sui Hedged Yield PoC (Economics + Math)

Goal:
  - Validate whether "Lending + CLMM LP + Perp Hedge (+ optional LST carry)" can
    plausibly produce positive net APY under different volatility regimes.

This is a *model* (not a backtest of on-chain fills). It is useful for:
  - investor-facing sanity checks
  - parameter sensitivity: fees / funding / range width / cycle frequency

Key ideas (English notes):
  - CLMM (Concentrated Liquidity Market Maker, Uniswap v3-style): has fee income
    but suffers IL (Impermanent Loss) due to being short gamma.
  - Delta hedge (Perp short): offsets directional exposure to the volatile asset.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import statistics
import sys
import urllib.request


def fetch_json(url: str, timeout: int = 20) -> dict:
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return json.load(resp)


def load_prices_sui(days: int) -> tuple[list[float], str]:
    # CoinGecko id for Sui is typically "sui"
    url = (
        "https://api.coingecko.com/api/v3/coins/sui/market_chart"
        f"?vs_currency=usd&days={days}&interval=daily"
    )
    try:
        data = fetch_json(url)
        prices = [point[1] for point in data.get("prices", [])]
        if len(prices) >= 2:
            return prices, "coingecko:sui"
    except Exception:
        pass

    # Fallback: synthetic mean-reverting-ish walk around $1
    rng = random.Random(42)
    prices = [1.0]
    for _ in range(days - 1):
        shock = rng.gauss(0.0, 0.03)
        drift = -0.02 * (prices[-1] - 1.0)
        nxt = max(0.05, prices[-1] * (1.0 + drift + shock))
        prices.append(nxt)
    return prices, "synthetic"


def daily_returns(prices: list[float]) -> list[float]:
    out: list[float] = []
    for i in range(1, len(prices)):
        p0 = prices[i - 1]
        p1 = prices[i]
        out.append(0.0 if p0 == 0 else (p1 - p0) / p0)
    return out


def regime_from_abs_return(abs_r: float, calm: float, storm: float) -> str:
    if abs_r < calm:
        return "CALM"
    if abs_r < storm:
        return "NORMAL"
    return "STORM"


def clamp(x: float, lo: float, hi: float) -> float:
    return lo if x < lo else hi if x > hi else x


def v3_amounts_for_L(
    L: float, p: float, p_low: float, p_high: float
) -> tuple[float, float]:
    """
    Uniswap v3-like formulas (token0, token1) where:
      - token0 = base asset (SUI)
      - token1 = quote asset (USDC)
      - price p = USDC per SUI (token1/token0)
    """
    sqrt_p = math.sqrt(p)
    sqrt_pl = math.sqrt(p_low)
    sqrt_ph = math.sqrt(p_high)

    if p <= p_low:
        # all token0 (SUI)
        amount0 = L * (sqrt_ph - sqrt_pl) / (sqrt_pl * sqrt_ph)
        amount1 = 0.0
        return amount0, amount1

    if p >= p_high:
        # all token1 (USDC)
        amount0 = 0.0
        amount1 = L * (sqrt_ph - sqrt_pl)
        return amount0, amount1

    # in-range: both tokens
    amount0 = L * (sqrt_ph - sqrt_p) / (sqrt_p * sqrt_ph)
    amount1 = L * (sqrt_p - sqrt_pl)
    return amount0, amount1


def v3_value_from_L(L: float, p: float, p_low: float, p_high: float) -> float:
    amount0, amount1 = v3_amounts_for_L(L, p, p_low, p_high)
    return amount0 * p + amount1


def solve_L_for_value(v0: float, p0: float, p_low: float, p_high: float) -> float:
    """
    Solve L such that v3_value_from_L(L, p0, p_low, p_high) ~= v0.
    Value is linear in L, so we can compute in one shot.
    """
    unit = v3_value_from_L(1.0, p0, p_low, p_high)
    if unit <= 0:
        return 0.0
    return v0 / unit


def ascii_curve(curve: list[float], width: int = 60) -> str:
    if not curve:
        return ""
    step = max(1, len(curve) // width)
    sampled = curve[::step][:width]
    lo = min(sampled)
    hi = max(sampled)
    span = hi - lo if hi != lo else 1.0
    levels = "._-~:+=*#%@"
    out = []
    for v in sampled:
        idx = int((v - lo) / span * (len(levels) - 1))
        out.append(levels[idx])
    return "".join(out)


def max_drawdown(curve: list[float]) -> float:
    peak = -1e18
    mdd = 0.0
    for v in curve:
        if v > peak:
            peak = v
        if peak > 0:
            dd = (peak - v) / peak
            mdd = max(mdd, dd)
    return mdd


def simulate(
    prices: list[float],
    tvl: float,
    calm_th: float,
    storm_th: float,
    range_width_bps: int,
    # allocations
    alloc_calm: tuple[float, float, float],
    alloc_normal: tuple[float, float, float],
    alloc_storm: tuple[float, float, float],
    # yield splits inside "yield" bucket
    lst_share_calm: float,
    lst_share_normal: float,
    lst_share_storm: float,
    # apr assumptions
    lending_apr_calm: float,
    lending_apr_normal: float,
    lending_apr_storm: float,
    lst_staking_apr: float,
    lp_fee_apr_calm: float,
    lp_fee_apr_normal: float,
    lp_fee_apr_storm: float,
    short_funding_apr_calm: float,
    short_funding_apr_normal: float,
    short_funding_apr_storm: float,
    # friction assumptions
    lp_rebalance_cost_bps: int,
    hedge_trade_fee_bps: int,
) -> dict:
    rets = daily_returns(prices)
    width = range_width_bps / 10_000.0

    V = tvl
    curve = [V]
    daily_net = []
    regimes = []

    for i, r in enumerate(rets, start=1):
        p0 = prices[i - 1]
        p1 = prices[i]
        abs_r = abs(r)
        regime = regime_from_abs_return(abs_r, calm_th, storm_th)
        regimes.append(regime)

        if regime == "CALM":
            yield_w, lp_w, buf_w = alloc_calm
            lst_share = lst_share_calm
            lend_apr = lending_apr_calm
            lp_apr = lp_fee_apr_calm
            fund_apr = short_funding_apr_calm
        elif regime == "NORMAL":
            yield_w, lp_w, buf_w = alloc_normal
            lst_share = lst_share_normal
            lend_apr = lending_apr_normal
            lp_apr = lp_fee_apr_normal
            fund_apr = short_funding_apr_normal
        else:
            yield_w, lp_w, buf_w = alloc_storm
            lst_share = lst_share_storm
            lend_apr = lending_apr_storm
            lp_apr = lp_fee_apr_storm
            fund_apr = short_funding_apr_storm

        # Start-of-day bucket values
        V_yield = V * yield_w
        V_lp = V * lp_w
        V_buf = V * buf_w

        # Split yield bucket into USDC lending vs SUI LST carry
        V_lst = V_yield * clamp(lst_share, 0.0, 1.0)
        V_lend = V_yield - V_lst

        # ===== Lending (USDC) =====
        V_lend_end = V_lend * (1.0 + lend_apr / 365.0)

        # ===== LST carry (SUI) =====
        # Buy SUI at p0, earn staking yield in SUI, mark-to-market at p1.
        lst_qty_sui = 0.0 if p0 <= 0 else V_lst / p0
        lst_qty_sui_end = lst_qty_sui * (1.0 + lst_staking_apr / 365.0)
        V_lst_end_unhedged = lst_qty_sui_end * p1

        # ===== CLMM LP (v3-style) =====
        # Provide liquidity in range centered at p0 with width `width`.
        p_low = max(1e-9, p0 * (1.0 - width))
        p_high = p0 * (1.0 + width)
        L = solve_L_for_value(V_lp, p0, p_low, p_high)

        amt0_sui_start, amt1_usdc_start = v3_amounts_for_L(L, p0, p_low, p_high)
        V_lp_end = v3_value_from_L(L, p1, p_low, p_high)

        # Fee income model (APY proxy)
        V_lp_end *= 1.0 + lp_apr / 365.0

        # Rebalance friction proxy (swap fees + slippage + routing)
        V_lp_end *= 1.0 - (lp_rebalance_cost_bps / 10_000.0)

        # ===== Perp hedge (short SUI) =====
        # Hedge SUI delta at start-of-day: (LST SUI qty + LP SUI amount0).
        hedge_qty = lst_qty_sui + amt0_sui_start
        notional0 = hedge_qty * p0

        # Funding (positive means *cost* to shorts in this model)
        funding_cost = notional0 * (fund_apr / 365.0)

        # Trading fee for adjusting hedge daily (proxy)
        hedge_fee = notional0 * (hedge_trade_fee_bps / 10_000.0)

        # Price PnL of short
        perp_pnl = hedge_qty * (p0 - p1)

        # Combine
        V_end = (
            V_lend_end
            + V_lst_end_unhedged
            + V_lp_end
            + V_buf
            + perp_pnl
            - funding_cost
            - hedge_fee
        )

        daily_ret = 0.0 if V <= 0 else (V_end - V) / V
        daily_net.append(daily_ret)
        V = V_end
        curve.append(V)

    avg_daily = statistics.mean(daily_net) if daily_net else 0.0
    std_daily = statistics.pstdev(daily_net) if len(daily_net) > 1 else 0.0
    if std_daily == 0.0:
        sharpe = 0.0
    else:
        sharpe = (avg_daily / std_daily) * math.sqrt(365.0)

    apy = (1.0 + avg_daily) ** 365.0 - 1.0 if daily_net else 0.0
    return {
        "days": len(prices) - 1,
        "apy": apy,
        "avg_daily": avg_daily,
        "std_daily": std_daily,
        "sharpe": sharpe,
        "mdd": max_drawdown(curve),
        "cumulative": (curve[-1] / curve[0] - 1.0) if curve and curve[0] else 0.0,
        "regimes": regimes,
        "curve": [v / curve[0] for v in curve] if curve and curve[0] else [],
    }


def main() -> int:
    p = argparse.ArgumentParser(description="Sui hedged yield PoC simulator")
    p.add_argument("--days", type=int, default=180)
    p.add_argument("--tvl", type=float, default=100_000.0)

    p.add_argument("--calm", type=float, default=0.01, help="CALM threshold (abs daily return)")
    p.add_argument("--storm", type=float, default=0.03, help="STORM threshold (abs daily return)")
    p.add_argument("--range-width-bps", type=int, default=1000, help="+/- range width, bps")

    p.add_argument("--lp-rebalance-cost-bps", type=int, default=3)
    p.add_argument("--hedge-trade-fee-bps", type=int, default=1)

    # Optional overrides (useful for sensitivity runs)
    p.add_argument(
        "--alloc-calm",
        type=str,
        default="0.40,0.57,0.03",
        help="Yield,LP,Buffer weights (sum~1). e.g. 0.40,0.57,0.03",
    )
    p.add_argument(
        "--alloc-normal",
        type=str,
        default="0.60,0.37,0.03",
        help="Yield,LP,Buffer weights (sum~1). e.g. 0.60,0.37,0.03",
    )
    p.add_argument(
        "--alloc-storm",
        type=str,
        default="0.80,0.17,0.03",
        help="Yield,LP,Buffer weights (sum~1). e.g. 0.80,0.17,0.03",
    )

    p.add_argument("--lst-share-calm", type=float, default=0.60)
    p.add_argument("--lst-share-normal", type=float, default=0.40)
    p.add_argument("--lst-share-storm", type=float, default=0.00)

    p.add_argument("--lending-apr-calm", type=float, default=0.05)
    p.add_argument("--lending-apr-normal", type=float, default=0.06)
    p.add_argument("--lending-apr-storm", type=float, default=0.05)
    p.add_argument("--lst-staking-apr", type=float, default=0.04)

    p.add_argument("--lp-fee-apr-calm", type=float, default=0.12)
    p.add_argument("--lp-fee-apr-normal", type=float, default=0.20)
    p.add_argument("--lp-fee-apr-storm", type=float, default=0.28)

    # In this model: positive = cost to shorts, negative = revenue to shorts.
    p.add_argument("--short-funding-apr-calm", type=float, default=0.03)
    p.add_argument("--short-funding-apr-normal", type=float, default=0.04)
    p.add_argument("--short-funding-apr-storm", type=float, default=0.06)

    args = p.parse_args()

    prices, source = load_prices_sui(args.days)

    def parse3(s: str) -> tuple[float, float, float]:
        parts = [x.strip() for x in s.split(",") if x.strip()]
        if len(parts) != 3:
            raise ValueError(f"expected 3 comma-separated floats, got: {s!r}")
        a, b, c = (float(parts[0]), float(parts[1]), float(parts[2]))
        return (a, b, c)

    alloc_calm = parse3(args.alloc_calm)
    alloc_normal = parse3(args.alloc_normal)
    alloc_storm = parse3(args.alloc_storm)

    result = simulate(
        prices=prices,
        tvl=args.tvl,
        calm_th=args.calm,
        storm_th=args.storm,
        range_width_bps=args.range_width_bps,
        alloc_calm=alloc_calm,
        alloc_normal=alloc_normal,
        alloc_storm=alloc_storm,
        lst_share_calm=args.lst_share_calm,
        lst_share_normal=args.lst_share_normal,
        lst_share_storm=args.lst_share_storm,
        lending_apr_calm=args.lending_apr_calm,
        lending_apr_normal=args.lending_apr_normal,
        lending_apr_storm=args.lending_apr_storm,
        lst_staking_apr=args.lst_staking_apr,
        lp_fee_apr_calm=args.lp_fee_apr_calm,
        lp_fee_apr_normal=args.lp_fee_apr_normal,
        lp_fee_apr_storm=args.lp_fee_apr_storm,
        short_funding_apr_calm=args.short_funding_apr_calm,
        short_funding_apr_normal=args.short_funding_apr_normal,
        short_funding_apr_storm=args.short_funding_apr_storm,
        lp_rebalance_cost_bps=args.lp_rebalance_cost_bps,
        hedge_trade_fee_bps=args.hedge_trade_fee_bps,
    )

    regimes = result["regimes"]
    counts = {"CALM": 0, "NORMAL": 0, "STORM": 0}
    for r in regimes:
        counts[r] += 1

    print("Sui Hedged Yield PoC — Summary")
    print("Price source:", source)
    print("Days:", result["days"])
    print("Regime days:", counts)
    print(f"APY (geom): {result['apy']*100:.2f}%")
    print(f"Sharpe: {result['sharpe']:.2f}")
    print(f"Max Drawdown: {result['mdd']*100:.2f}%")
    print(f"Cumulative: {result['cumulative']*100:.2f}%")
    print("Curve:", ascii_curve(result["curve"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
