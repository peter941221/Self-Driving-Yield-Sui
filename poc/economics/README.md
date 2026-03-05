# Economics PoC — Sui Hedged Yield Simulator

This PoC is a **math/economics simulator** for the Sui version of Self-Driving Yield.

It answers:
- Is the current "Lending + CLMM LP + Perp Hedge (+ optional LST carry)" design *directionally* viable?
- How sensitive is net APY to: `LP fees`, `range width`, `funding`, `rebalance costs`?

## What This Is (and Isn't)

✅ Useful for:
- sanity checking parameter ranges (investor-friendly)
- comparing regimes (CALM / NORMAL / STORM)
- identifying which variable dominates returns (fees vs funding vs IL)

❌ Not a real execution backtest:
- no on-chain fills / slippage curve
- no funding history (we model funding as regime-dependent APR)
- LP fee APR is a proxy (not from Cetus on-chain data yet)

## Run

```bash
python poc/economics/sui_hedged_lp_sim.py --days 180
```

Common knobs:
- `--range-width-bps 500`  (narrower CLMM range = more fee efficiency, more out-of-range risk)
- `--lp-rebalance-cost-bps 10`  (higher swap/slippage cost)
- `--hedge-trade-fee-bps 3`     (more expensive hedge adjustments)

## Model Overview (Key Terms)

- `CLMM` (Concentrated Liquidity Market Maker): Uniswap v3-style LP math.
- `IL` (Impermanent Loss): LP underperforms HODL when price moves.
- `Delta Hedge` (Perp short): short the volatile asset to neutralize directional exposure.
- `Funding` (Perp funding rate): carry cost/benefit of holding the hedge.

In code we:
1. Load daily SUI price (CoinGecko) or fallback to synthetic.
2. Detect regime from abs daily return.
3. Apply regime allocations:
   - Yield bucket (Lending + optional LST carry)
   - LP bucket (CLMM range around price)
   - Buffer bucket
4. Short SUI perps against the start-of-day SUI exposure (LST + LP token0 amount).
5. Compute net daily return, APY, Sharpe, max drawdown.

