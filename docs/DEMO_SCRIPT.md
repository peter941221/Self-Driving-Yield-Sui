# Demo Script (3 Minutes)

This script is a short talk track plus commands to run during the demo.


## 0) Setup (Before Recording)

```bash
export BSC_RPC_URL="https://bsc-dataseed.binance.org/"
```


## 1) 0:00 - 0:20 Intro

Say:

- "This is a fully autonomous yield engine on BNB Chain."

- "It reallocates between ALP and Pancake LP based on on-chain volatility."


## 2) 0:20 - 0:50 Architecture Quick Tour

Say:

- "EngineVault is the brain. It calls adapters and the oracle."

- "VolatilityOracle provides regime switching."

- "FlashRebalancer and WithdrawalQueue complete the automation."

Show:

- `README.md` sections: Key Ideas, Architecture, Core Contracts.


## 3) 0:50 - 1:30 Tests (Quality Proof)

Run:

```bash
forge test
```

Optional fork checks:

```bash
export BSC_RPC_URL="https://bsc-dataseed.binance.org/"
forge test --match-path test/ForkSuite.t.sol
```

Say:

- "All tests are green, including invariant and risk-mode tests."

- "Fork suite A-F confirms key on-chain addresses and reserves."


## 4) 1:30 - 2:30 Fork Demo (Live Cycle)

Run:

```bash
forge script script/ForkCycleDemo.s.sol
```

Say:

- "We deposit USDT, run cycle(), and the vault rebalances into BTCB/USDT LP."

- "You can see base/quote balances change after swap + addLiquidity."


## 5) 2:30 - 3:00 Risk & Closing

Say:

- "Risk controls include ONLY_UNWIND mode, gas/bounty caps, and TWAP warmup."

- "All parameters are immutable; there is no admin or keeper."

- "Next steps: strengthen economic calibration and final audit checks."


## On-screen Checklist

- `README.md`

- `THREAT_MODEL.md`

- `ECONOMICS.md`

- `script/ForkCycleDemo.s.sol`


## Latest Run Outputs (2026-02-23)

```
forge test
- 20 tests passed, 0 failed

forge test --match-path test/ForkSuite.t.sol
- 6 tests passed, 0 failed

forge script script/ChainChecks.s.sol --rpc-url https://bsc-dataseed.binance.org/
- INIT_CODE_HASH confirmed via factory INIT_CODE_PAIR_HASH
```
