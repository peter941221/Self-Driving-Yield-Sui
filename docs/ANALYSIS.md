# Hackathon Analysis

This document completes the problem analysis, competitive landscape, and core innovation summary.


## Part1 Problem Analysis and Evaluation

Goals and constraints:

- Four pillars: Integrate / Stack / Automate / Protect.

- Constraints: non-custodial, no admin, permissionless execution.


Design Prompts -> Solution Mapping:

- Hedging: short BTCB exposure via 1001x; use delta band to control open/close.

- Volatility: cumulative TWAP + MIN_SAMPLES warmup; regime switching.

- Resilience: ONLY_UNWIND risk mode + atomic Flash Rebalance + withdrawal queue.


Internal Rubric (non-official):

- Integrate 30

- Stack 25

- Automate 25

- Protect 20


Iteration Loop:

```
Observe  ->  Diagnose  ->  Adjust  ->  Validate  ->  Record
  |            |            |            |            |
  |            |            |            |            └─ update docs/params
  |            |            |            └─ fork/invariant tests
  |            |            └─ adjust thresholds/allocations/guards
  |            └─ analyze yield/risk/deviation
  └─ read on-chain state/events
```


## Part2 Competitive Landscape

Case A: GMX GLP-style vault (auto-compounders)

- Pros: diversified yield (fees + funding + liquidations), simple UX.

- Cons: depends on a single asset pool; no explicit IL hedge.


Case B: Pancake V2 LP auto-compounder

- Pros: strong compounding, transparent fees.

- Cons: IL exposure is high; no volatility-adaptive allocation.


Case C: Delta-neutral structured vault (spot + perp)

- Pros: explicit hedging, risk can be quantified.

- Cons: frequent rebalancing; sensitive to gas and funding.


Non-custodial conflict (asUSDF):

- Strategies that rely on permissioned stables or custody pools conflict with non-custodial goals.

- This design avoids asUSDF and keeps parameters immutable.


Differentiation Matrix:

```
+----------------------+---------------------------+-----------------------------+
| Dimension            | Traditional LP Vault      | Self-Driving Engine         |
+----------------------+---------------------------+-----------------------------+
| Volatility response  | Fixed allocation          | Regime-based dynamic mix    |
| Hedging              | None                      | 1001x short hedge           |
| Rebalance            | Multi-transaction         | Flash atomic rebalance      |
| Automation           | Semi-auto / keeper        | permissionless cycle()      |
+----------------------+---------------------------+-----------------------------+
```


## Part3 Core Innovation (Dual-Engine ALP)

ALP yield components (see `ECONOMICS.md`):

- Trading fees.

- Funding income.

- Liquidation proceeds.


Why ALP hedges LP IL:

```
Volatility rises
   |
   |-- LP IL risk increases
   |
   `-- Trading volume and liquidations increase
          |
          `-- ALP revenue increases

=> ALP revenue is positively correlated with volatility
```


Math and allocation principles (simplified):

- Target mix = f(volatility), driven by regime.

- Hedge gap = LP base exposure - short exposure.

- If gap > band: open more short; if gap < -band: reduce short.


Resilience:

- ONLY_UNWIND blocks risk-increasing actions.

- Bounty cap + gasPrice cap prevent abuse.

- Partial withdraw reduces liquidity stress.
