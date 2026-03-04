# DoraHacks Submission Text

## Project Name
Self-Driving Yield Engine (Aster Dual-Engine Vault)

## One-Line Pitch
An autonomous yield vault that uses Aster ALP as both a yield engine AND a natural hedge against LP impermanent loss — no admin, no keeper, no trust required.

---

## The Problem

```
┌────────────────────────────────────────────────────────────────┐
│  LP Pain: Impermanent loss eats yield                          │
│  Old Way: Manual rebalance is slow, MEV bots front-run         │
│  Custody Risk: Multisig/admins can rug pull                    │
└────────────────────────────────────────────────────────────────┘
```

When volatility spikes, LPs bleed impermanent loss. Traditional vaults either:
- Stay static and lose money
- Rely on trusted keepers (centralization risk)
- Get front-run by MEV bots during rebalancing

---

## Our Solution

A **fully autonomous** yield engine with a novel insight:

> **ALP is a "short volatility" position** — it earns MORE when markets are volatile.
> This naturally offsets LP impermanent loss during market stress.

```
        CALM MARKET            STORM MARKET
        ┌─────────┐            ┌─────────┐
   LP   │  ████   │ High yield  │  ██     │ IL loss
   ALP  │  ███    │ Stable      │  ██████ │ High yield (hedge!)
        └─────────┘            └─────────┘
        
        → Auto rebalance ←
```

### Four Pillars Alignment

| Pillar | Implementation |
|--------|----------------|
| **Integrate** | Aster ALP + Pancake V2 + 1001x delta hedge |
| **Stack** | ALP yield → LP fees → hedge funding, triple-compounding |
| **Automate** | Permissionless `cycle()` with bounded bounty incentive |
| **Protect** | 0 admin, immutable params, atomic flash rebalance |

---

## Design Highlights

### 1. ALP as Endogenous Hedge
- ALP earns from trading fees + liquidations = profits from volatility
- LP suffers from IL = losses from volatility
- **Result**: Natural hedge without external derivatives

### 2. Regime-Switching Oracle
```
  CALM (vol<1%)    →  ALP 40% / LP 57%  →  ~10% APY
  NORMAL (1-3%)    →  ALP 60% / LP 37%  →  ~12% APY  
  STORM (≥3%)      →  ALP 80% / LP 17%  →  ~17% APY
```

### 3. MEV-Resistant Rebalancing
- Flash Swap borrows → rebalances → repays in one atomic tx
- No external DEX calls that can be sandwiched
- Slippage/deadline guards built-in

### 4. Risk Resilience
- `ONLY_UNWIND` mode: TWAP vs spot deviation > 5% triggers safe unwind
- No risky capital deployment during flash crashes
- Gas/bounty caps prevent over-trading

---

## Technical Execution

| Metric | Status |
|--------|--------|
| Solidity Version | 0.8.20 (Foundry) |
| Test Coverage | 40/40 passing (unit + invariant + fork) |
| Static Analysis | Slither 0 warnings (with documented exclusions) |
| On-chain Verification | Fork suite A-F validated |
| Documentation | README + ARCHITECTURE + ECONOMICS + THREAT_MODEL |

### Core Contracts
- `EngineVault.sol` — ERC-4626 style vault with regime switching
- `VolatilityOracle.sol` — TWAP-based volatility measurement
- `FlashRebalancer.sol` — Atomic rebalance via flash swap
- `WithdrawalQueue.sol` — Permissionless withdrawal claims
- `AsterAlpAdapter.sol` / `PancakeV2Adapter.sol` / `Aster1001xAdapter.sol`

---

## Why This Can Win

1. **Novel Insight**: First vault to use ALP's volatility-preferring returns as an IL hedge
2. **Truly Trustless**: No admin key, no keeper dependency, parameters are immutable
3. **Production-Ready**: Comprehensive tests, documented threat model, economic calibration
4. **Hackathon Pillar-Aligned**: Explicitly addresses Integrate/Stack/Automate/Protect

---

## GitHub Repository
https://github.com/peter941221/Hackathon-Self-Driving-Yield

## Demo Video
https://www.youtube.com/watch?v=rdQyEShM0vs