# Self-Driving Yield Engine (Sui Move)

<p align="center">
  <strong>An autonomous yield vault that hedges itself</strong>
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=rdQyEShM0vs">
  <img src="https://img.shields.io/badge/Demo-Video-red?style=for-the-badge&logo=youtube" alt="Demo Video">
  </a>
  <img src="https://img.shields.io/badge/Tests-40%2F40%20Passing-brightgreen?style=for-the-badge" alt="Tests">
  <img src="https://img.shields.io/badge/Platform-Sui%20Move-yellow?style=for-the-badge" alt="Platform">
  <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="License">
</p>

---

## What is this?

An **autonomous, non-custodial yield engine** migrating to **Sui Move**.

**Key insight** (Sui version): a vault can **adapt to volatility** and manage risk automatically:
- In calm markets: allocate more to fee-generating liquidity (CLMM LP).
- In stressed markets: rotate into safer carry (USDC lending) and reduce risky exposure.
- Optional: use **on-chain perps** to hedge delta exposure (where composable/permissionless).

```
     CALM MARKET          STORM MARKET
     ┌─────────┐          ┌─────────┐
LP   │  ████   │ Fees     │  ██     │ Reduce LP / unwind
Carry│  ███    │ Stable   │  █████  │ Lending-first defense
     └─────────┘          └─────────┘
     
                    → Auto rebalance ←
```

SSOT (Single Source of Truth): `技术文档.md`

## Demo Video

**[Watch the 3-minute demo on YouTube](https://www.youtube.com/watch?v=rdQyEShM0vs)**

---

## Key Ideas

- Volatility-aware allocation: CALM / NORMAL / STORM regimes.

- Regime Switching: CALM / NORMAL / STORM allocations shift automatically.

- Permissionless Automation: anyone can call `cycle()` and earn a bounded bounty.

- Atomic Rebalance: Flash Swap rebalances reduce MEV surface.

- No Admin: all parameters are immutable, no multisig or keeper dependency.


## Design Philosophy

- Why: static vaults ignore volatility; this vault adapts while staying non-custodial.

- What: a self-driving engine allocating across ALP, Pancake V2 LP, and 1001x delta hedging.

- How: TWAP-based regime switching, bounded cycle bounty, and atomic flash rebalances.

- Assumptions: protocol ABIs remain stable, on-chain liquidity is sufficient, BSC finality is normal.

- Sustainability: rebalance only when deviation beats costs; gas/bounty caps prevent overtrading.

- Resilience: ONLY_UNWIND risk mode, partial withdrawals, slippage/deadline guards.

Assumptions and mitigations are expanded in `技术文档.md` and `THREAT_MODEL.md`.


## Hackathon Pillars

- Integrate (Sui): Pyth + Cetus CLMM + Lending + Aftermath Perps.

- Stack: lending carry + LP fees + hedge/funding dynamics.

- Automate: permissionless `cycle()` with bounded bounty.

- Protect: TWAP guardrails, flash atomicity, and risk mode safeguards.


## Legacy Implementation Notes (BNB Prototype)

> ⚠️ These notes reference the original BNB Chain prototype (ALP / Pancake / 1001x).
> The current Sui Move SSOT is `技术文档.md`.

- LP rebalancing uses on-chain swaps when the base/quote ratio is off target.

- Flash rebalance computes a borrow amount from LP deviation and caps it to 10% of reserves.

- Flash callbacks repay in the opposite token using on-chain reserves.

- Borrowed flash amounts are excluded from target allocation calculations.

- 1001x position size sums short `qty` from `getPositionsV2(address,address)` and exposes avg entry price.


## Architecture (High-Level)

```
User (Native USDC)
  -> EngineVault (Sui shared object + Coin<SDYE> shares)
     -> yield_source (Lending carry + optional LST carry)
     -> cetus_amm (CLMM LP)
     -> perp_hedge (Aftermath Perps)
     -> oracle (Pyth pull + TWAP vol)
     -> queue (withdraw requests + permissionless claim)
```

### Legacy `cycle()` Flow (BNB Prototype, Mermaid)

```mermaid
%%{init: {"theme":"base","themeVariables":{"fontFamily":"ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace","lineColor":"#475569","primaryColor":"#e8f3ff","primaryBorderColor":"#2563eb","primaryTextColor":"#0f172a"}}}%%
flowchart TD
  A[cycle called by anyone] --> B[Phase 0 pre-checks<br/>slippage deadline gas bounty caps]
  B --> C[Phase 1 read state<br/>ALP LP hedge cash]
  C --> D[Phase 2 TWAP snapshot]
  D --> E{min samples ready}
  E -->|No| F[Force NORMAL<br/>skip flash rebalance]
  E -->|Yes| G[Compute regime<br/>CALM NORMAL STORM]
  F --> H[Phase 3 target allocation]
  G --> H
  H --> I{RiskMode ONLY_UNWIND}
  I -->|Yes| J[Reduce-only path<br/>unwind hedge remove LP burn ALP]
  I -->|No| K[Select rebalance path]
  K --> L{Deviation exceeds threshold}
  L -->|Yes| M[FlashRebalancer atomic path]
  L -->|No| N[Incremental swap and LP adjustment]
  M --> O[Phase 5 hedge adjustment]
  N --> O
  J --> O
  O --> P{Health + deviation safe}
  P -->|No| Q[Set ONLY_UNWIND and emit risk event]
  P -->|Yes| R[Stay NORMAL]
  Q --> S[Phase 6 bounded bounty payout]
  R --> S
  S --> T[Emit CycleCompleted and accounting events]

  classDef start fill:#fde68a,stroke:#d97706,color:#111827,stroke-width:2px
  classDef compute fill:#ccfbf1,stroke:#0f766e,color:#0f172a,stroke-width:1.8px
  classDef decision fill:#dbeafe,stroke:#1d4ed8,color:#0f172a,stroke-width:1.8px
  classDef risk fill:#fecaca,stroke:#b91c1c,color:#111827,stroke-width:1.8px
  classDef rebalance fill:#fef3c7,stroke:#b45309,color:#111827,stroke-width:1.8px
  classDef stable fill:#dcfce7,stroke:#15803d,color:#111827,stroke-width:1.8px

  class A,S,T start
  class B,C,D,F,G,H,O compute
  class E,I,L,P decision
  class J,Q risk
  class M,N rebalance
  class R stable
```


## Core Contracts

- `contracts/core/EngineVault.sol`

- `contracts/core/VolatilityOracle.sol`

- `contracts/core/WithdrawalQueue.sol`

- `contracts/adapters/FlashRebalancer.sol`


## Libraries & Interfaces

- `contracts/libs/PancakeOracleLibrary.sol`

- `contracts/libs/PancakeLibrary.sol`

- `contracts/libs/MathLib.sol`

- `contracts/interfaces/IAsterDiamond.sol`


## Docs

- Architecture: `ARCHITECTURE.md`

- Economics: `ECONOMICS.md`

- Hackathon analysis: `docs/ANALYSIS.md`

- On-chain checks: `docs/ONCHAIN_CHECKS.md`

- Slither notes: `docs/SLITHER_NOTES.md`

- Louper Selector Map: `docs/LOUPER_MAP.md`

- Fork demo script: `script/ForkCycleDemo.s.sol`

- Threat model: `THREAT_MODEL.md`

- Demo runbook: `docs/DEMO_SCRIPT.md`

- Demo storyboard: `docs/DEMO_STORYBOARD.md`

- Submission checklist: `docs/SUBMISSION_CHECKLIST.md`


## Quickstart (Foundry)

```bash
forge build
forge test
forge fmt
```

Invariant tests:

```bash
forge test --match-path test/Invariant.t.sol
```

Negative tests:

```bash
forge test --match-path test/EngineVaultRiskMode.t.sol
```


## Fork Tests (BSC)

Set the following environment variable for forked tests:

```bash
export BSC_RPC_URL="https://bsc-dataseed.binance.org/"
forge test
```

Fork suite (A-F):

```bash
forge test --match-path test/ForkSuite.t.sol
```

Adapter fork checks:

```bash
forge test --match-path test/*Adapter.t.sol
```

Optional:

```bash
export BSC_FORK_BLOCK=82710000
```


## On-Chain Verification

```bash
forge script script/ChainChecks.s.sol --rpc-url "https://bsc-dataseed.binance.org/"
cast call 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73 "INIT_CODE_PAIR_HASH()(bytes32)" --rpc-url https://bsc-dataseed.binance.org/
```


## Testnet Deployment (BSC)

Deployment script: `script/Deploy.s.sol`

```bash
export BSC_TESTNET_RPC_URL="https://data-seed-prebsc-1-s1.binance.org:8545/"
export PRIVATE_KEY="<your key>"
forge script script/Deploy.s.sol --rpc-url "$BSC_TESTNET_RPC_URL" --broadcast --verify
```

Deployed addresses (fill after broadcast):

- EngineVault: TBD

- VolatilityOracle: TBD

- WithdrawalQueue: TBD

- FlashRebalancer: TBD


## Static Analysis

```bash
slither . --exclude-dependencies --exclude incorrect-equality,timestamp,low-level-calls,naming-convention,cyclomatic-complexity
```

See notes in `docs/SLITHER_NOTES.md`.


## Submission

Use `docs/SUBMISSION_CHECKLIST.md` and `docs/DEMO_SCRIPT.md` for the final submission.


## Status

This repository contains the complete smart contract suite, test coverage, and documentation for the Self-Driving Yield Engine. All tests pass locally. Fork suite A-F validates on-chain integrations.
