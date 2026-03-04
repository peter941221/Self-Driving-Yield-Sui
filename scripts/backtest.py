#!/usr/bin/env python3
import argparse
import json
import math
import random
import statistics
import urllib.request


def fetch_json(url, timeout=20):
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.load(response)


def load_prices(days):
    url = f"https://api.coingecko.com/api/v3/coins/bitcoin/market_chart?vs_currency=usd&days={days}&interval=daily"
    try:
        data = fetch_json(url)
        prices = [point[1] for point in data.get("prices", [])]
        if len(prices) >= 2:
            return prices, "coingecko"
    except Exception:
        pass

    random.seed(42)
    prices = [45000.0]
    for _ in range(days - 1):
        drift = random.uniform(-0.02, 0.02)
        prices.append(prices[-1] * (1.0 + drift))
    return prices, "synthetic"


def daily_returns(prices):
    returns = []
    for i in range(1, len(prices)):
        prev = prices[i - 1]
        curr = prices[i]
        if prev == 0:
            returns.append(0.0)
        else:
            returns.append((curr - prev) / prev)
    return returns


def regime_from_vol(vol):
    if vol < 0.01:
        return "CALM"
    if vol < 0.03:
        return "NORMAL"
    return "STORM"


def simulate(prices, bnb_price=300.0, gas_gwei=50.0, cycles_per_day=4, tvl=100000.0):
    alloc = {
        "CALM": (0.40, 0.57),
        "NORMAL": (0.60, 0.37),
        "STORM": (0.80, 0.17),
    }
    alp_yield = {
        "CALM": 0.15,
        "NORMAL": 0.18,
        "STORM": 0.22,
    }
    lp_yield = {
        "CALM": 0.08,
        "NORMAL": 0.12,
        "STORM": 0.16,
    }

    gas_used = 250000
    daily_gas_cost = (gas_gwei * 1e-9) * gas_used * cycles_per_day * bnb_price
    rng = random.Random(42)

    rets = daily_returns(prices)
    daily_net = []
    regimes = []
    for r in rets:
        vol = abs(r)
        regime = regime_from_vol(vol)
        regimes.append(regime)
        alp_alloc, lp_alloc = alloc[regime]
        alp_noise = rng.uniform(-0.03, 0.03)
        lp_noise = rng.uniform(-0.03, 0.03)
        alp_component = max(0.0, alp_yield[regime] + alp_noise)
        lp_component = max(0.0, lp_yield[regime] + lp_noise)

        gross = alp_alloc * alp_component + lp_alloc * lp_component
        il_cost = min(0.06, vol * 1.2)
        hedge_cost = 0.001 + vol * 0.2
        net = (gross - il_cost - hedge_cost) / 365.0
        net -= daily_gas_cost / tvl
        daily_net.append(net)

    avg_daily = statistics.mean(daily_net) if daily_net else 0.0
    min_daily = min(daily_net) if daily_net else 0.0
    max_daily = max(daily_net) if daily_net else 0.0
    std_daily = statistics.pstdev(daily_net) if len(daily_net) > 1 else 0.0
    if std_daily < 0.0005:
        std_daily = 0.0005

    apy_avg = avg_daily * 365.0
    apy_min = min_daily * 365.0
    apy_max = max_daily * 365.0
    sharpe = 0.0 if std_daily == 0 else (avg_daily / std_daily) * math.sqrt(365.0)

    cumulative = 1.0
    curve = [cumulative]
    for r in daily_net:
        cumulative *= 1.0 + r
        curve.append(cumulative)

    return {
        "regimes": regimes,
        "daily_net": daily_net,
        "apy": (apy_min, apy_avg, apy_max),
        "sharpe": sharpe,
        "cumulative": cumulative,
        "curve": curve,
    }


def ascii_curve(curve, width=40):
    if not curve:
        return ""
    step = max(1, len(curve) // width)
    sampled = curve[::step]
    if len(sampled) > width:
        sampled = sampled[:width]
    min_v = min(sampled)
    max_v = max(sampled)
    span = max_v - min_v if max_v != min_v else 1.0
    levels = "._-~:+=*#%@"
    out = []
    for v in sampled:
        idx = int((v - min_v) / span * (len(levels) - 1))
        out.append(levels[idx])
    return "".join(out)


def main():
    parser = argparse.ArgumentParser(
        description="Simple backtest for Self-Driving Yield Engine"
    )
    parser.add_argument("--days", type=int, default=90)
    parser.add_argument("--bnb-price", type=float, default=300.0)
    parser.add_argument("--gas-gwei", type=float, default=50.0)
    parser.add_argument("--cycles-per-day", type=int, default=4)
    parser.add_argument("--tvl", type=float, default=100000.0)
    args = parser.parse_args()

    prices, source = load_prices(args.days)
    result = simulate(
        prices, args.bnb_price, args.gas_gwei, args.cycles_per_day, args.tvl
    )

    regimes = result["regimes"]
    counts = {"CALM": 0, "NORMAL": 0, "STORM": 0}
    for r in regimes:
        counts[r] += 1

    apy_min, apy_avg, apy_max = result["apy"]
    curve = ascii_curve(result["curve"])

    print("Backtest Summary")
    print("Source:", source)
    print("Days:", args.days)
    print("Regime days:", counts)
    print(
        "APY min/avg/max:",
        f"{apy_min * 100:.2f}% / {apy_avg * 100:.2f}% / {apy_max * 100:.2f}%",
    )
    print("Sharpe:", f"{result['sharpe']:.2f}")
    print("Cumulative:", f"{(result['cumulative'] - 1.0) * 100:.2f}%")
    print("Curve:", curve)


if __name__ == "__main__":
    main()
