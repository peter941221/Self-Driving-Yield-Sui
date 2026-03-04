# Threat Model

This document summarizes the main risks, assumptions, and mitigations for the Self-Driving Yield Engine.


## Scope

- EngineVault core loop (cycle), adapters, oracle, flash rebalance, withdrawal queue.


## Assets at Risk

- User principal (USDT) and any base asset (BTCB).

- ALP tokens and Pancake LP tokens.

- Vault share accounting (mint/redeem fairness).


## Trust Assumptions

- PancakeSwap V2 router/factory/pair are correct and not malicious.

- Aster Diamond facets keep ABI behavior consistent.

- BSC network finality and transaction ordering are honest within normal conditions.


## Threats and Mitigations

1) MEV Sandwich / Price Impact

- Mitigation: slippage limits, deadlines, and atomic flash rebalance where possible.

- Residual risk: large rebalance can still move price or be sandwiched.

2) Oracle Manipulation

- Mitigation: TWAP (cumulative prices), min snapshot interval, MIN_SAMPLES warmup.

- Mitigation: price deviation checks can trigger ONLY_UNWIND mode.

3) Flash Loan / Flash Swap Abuse

- Mitigation: flash callback restricted to the pair and to the vault.

- Mitigation: repay amount computed from on-chain reserves.

4) Bounty Drain

- Mitigation: gasPrice cap, buffer cap, and max bounty based on assets.

5) Withdrawal Starvation

- Mitigation: partial claim, claim bounty, and unwind path.

6) ABI Drift (Aster Diamond)

- Mitigation: Louper selector map and typed interface alignment.

- Residual risk: future upgrades can change selector behavior.

7) Reentrancy / Callback Risk

- Mitigation: nonReentrant guards on EngineVault and WithdrawalQueue entrypoints.

- Mitigation: flash callback restricted to the pair and vault.


## Monitoring Signals

- CycleExecuted / RegimeSwitched / RiskModeChanged events.

- Bounty paid vs profit delta.

- Vault cash buffer vs pending withdrawals.


## Known Gaps

- Slither findings are documented in `docs/SLITHER_NOTES.md`; CI automation is still pending.

- Invariant coverage includes flash accounting, but full flash swap path coverage remains a follow-up.
