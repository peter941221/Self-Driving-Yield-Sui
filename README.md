# Self-Driving Yield Engine (Sui Move)

<p align="center">
  <strong>Queue-aware, regime-driven treasury execution on Sui with real protocol evidence.</strong>
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=rdQyEShM0vs">
    <img src="https://img.shields.io/badge/Demo-Video-red?style=for-the-badge&logo=youtube" alt="Demo Video">
  </a>
  <img src="https://img.shields.io/badge/Platform-Sui%20Move-yellow?style=for-the-badge" alt="Platform">
  <img src="https://img.shields.io/badge/Stage-P5%20Technical%20Closure-brightgreen?style=for-the-badge" alt="Stage">
  <img src="https://img.shields.io/badge/Release-Final%20Closure%20Open-orange?style=for-the-badge" alt="Release">
  <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="License">
</p>

Last verified: `2026-03-09`

---

## TL;DR

`Self-Driving Yield` is a Sui-native shared vault for treasury and yield management.

It is designed to:

- accept a base asset `Coin<BASE>`
- mint `SDYE` shares
- classify market regime from oracle snapshots
- reserve liquidity for queued withdrawals
- rebalance across LP / yield / hedge buckets
- degrade into `OnlyUnwind` under stress and restore only after safe cycles

The important point is not the design alone.

The repo already has real protocol evidence:

- real testnet lifecycle smoke
- real Cetus external-object `open -> close`
- a shared vault holding a real Cetus `Position` across transactions
- queue-pressure `cycle_live` closing a real position before `CycleEvent`
- native staking proof on testnet
- first real DeFi lending proof via Scallop `deposit -> query -> withdraw`

The honest current conclusion is:

```text
P5 technical closure = yes
final immutable release readiness = no
```

This is already good enough for technical diligence and early investor conversations.
It is not honest to present it as fully autonomous across every live leg or as final-release-ready today.

---

## Why This Exists

Most onchain vaults optimize only for yield.

This repo is trying to optimize for:

```text
yield
  + liquidity safety
  + queue survival
  + explicit risk mode transitions
  + auditable evidence of what has actually been proven
```

The target user is not retail-first.

The current customer hypothesis is:

- protocol treasuries
- onchain operators managing idle balances
- teams that care about queue pressure and unwind discipline

---

## What The System Does

```text
[Deposit BASE]
      |
      v
[Mint SDYE shares]
      |
      v
[Permissionless cycle()]
      |
      +--> read oracle snapshots
      +--> classify CALM / NORMAL / STORM
      +--> reserve for queued withdrawals
      +--> rebalance LP / Yield / Hedge buckets
      +--> pay bounded caller bounty
      |
      v
[Users redeem instantly or queue -> later claim()]
```

Risk mode behavior:

```text
[Normal]
   |
   v
[Stress / deviation / safety trigger]
   |
   v
[OnlyUnwind]
   |
   +--> can reduce exposure
   +--> cannot re-risk
   |
   v
[safe cycle #1]
   |
   v
[safe cycle #2]
   |
   v
[restore normal]
```

---

## Architecture

```text
                 +----------------------------------+
                 |     entrypoints::Vault<BASE>     |
                 |        shared object             |
                 +----------------+-----------------+
                                  |
          +-----------------------+------------------------+
          |                       |                        |
          v                       v                        v
+-------------------+   +-------------------+   +-------------------+
| vault::VaultState |   | oracle::Oracle    |   | queue::Withdrawal |
| shares / assets   |   | snapshots / vol   |   | pending / ready   |
| risk mode         |   | regime            |   | locked shares     |
+---------+---------+   +---------+---------+   +---------+---------+
          |                       |                        |
          +-----------------------+------------------------+
                                  |
                                  v
                  +---------------+----------------+
                  | adapters::cetus / lending /    |
                  | perps / flash / live helpers   |
                  +---------------+----------------+
                                  |
                                  v
                    +-------------+-------------+
                    | LP / Yield / Hedge buckets|
                    +---------------------------+
```

Main modules:

| Module | Responsibility |
|---|---|
| `vault.move` | share accounting, treasury accounting, risk mode, cycle core |
| `oracle.move` | snapshots, volatility, regime classification |
| `queue.move` | FIFO withdrawal queue, ready reserve, claim flow |
| `entrypoints.move` | shared-object deposit / withdraw / claim / cycle entry surface |
| `config.move` | operator parameters, adapter IDs, `seal()` release gate |
| `adapters/*.move` | accounting wrappers and live protocol helper paths |

---

## Current Status

| Track | Status | Meaning |
|---|---|---|
| `P1` core modules + tests | `DONE` | vault, oracle, queue, config base is in place |
| `P2` planner + adapters | `DONE` | planner signals and adapter accounting exist |
| `P3` lifecycle / safety tests | `DONE` | local lifecycle and concurrency coverage is in place |
| `P4` deploy / monitor / release artifacts | `DONE` | deploy, monitor, demo, release docs exist |
| `P5` live integration evidence | `DONE` | real LP and yield proof paths exist |
| `R1` final immutable release closure | `OPEN` | final release discipline is still not claimed as complete |

The strongest honest one-liner today is:

> We already have real protocol evidence, and the next step is turning those proof paths into a release-disciplined execution product.

---

## Evidence Ledger

This section is the single-page answer to: "What is actually proven right now?"

### 1) Local correctness headline

- `170 / 170 PASS`
- `94.85%` overall Move coverage
- key module snapshot:
  - `oracle`: `99.61%`
  - `entrypoints`: `95.98%`
  - `queue`: `95.62%`
  - `yield_source`: `97.31%`
  - `vault`: `93.49%`
  - `cetus_live`: `89.38%`
  - `cetus_amm`: `88.63%`

What it proves:

- the local correctness baseline is strong
- planner, queue, restore logic, and live helper layers are covered by current tests

What it does not prove:

- local coverage is not a substitute for live shared-object evidence

### 2) Testnet lifecycle smoke

- archived report: `out/reports/testnet_cycle_smoke_20260307T005500Z.json`
- manifest: `out/deployments/testnet_smoke.json`
- package: `0x96bad4d18461e2becbf0c658ab77f7d8569f6bb8c9ae58cefac1763ff9952c5c`
- vault: `0x8417436eafa436708ba9e5720376cbf229dec022d30dc5d8c488ec59cb203716`
- queue: `0xb61d9b25e58d758e2f245459f766670e8a01e5b120621892b6e5035d9518cc3c`
- config: `0x1c4519cdf4f05a31741ab86cbaf16b757c526e0db9e4db60dae501e4de779b63`
- key digests:
  - deposit: `DuCkCs6C2NTy52XqFmUhuVfB6i1NagAHHAyju1ueViEn`
  - cycle_1: `Dg9yuYZM6TxMs38gpFCjsRqsYTs7eXkjobofLu4BzTJ8`
  - cycle_12: `HzSRbZGjCFHcmAiA7ewHVnEoLwGVHwvfmHeLCKMrnMyi`

What it proves:

- `publish -> bootstrap -> deposit -> repeated cycle -> monitor` works on testnet

What it does not prove:

- this smoke manifest still uses `0x0` adapter IDs, so it is lifecycle evidence, not live external-object integration proof

### 3) Real Cetus external-object `open -> close`

- archived report: `out/reports/cetus_live_probe_20260307T084718Z.json`
- manifest: `out/deployments/testnet_cetus_live.json`
- package: `0x5d765c15ebd4b020fda2ae82fec53cbaaf241344c75b6534e5d0d75ea808b684`
- Cetus pool: `0xe8bee419df59bf9b71666255e3956ad8e324b03f39a2c413f174cb157fd84cd8`
- open digest: `A9Zx6ae2AVgAVuHUHLmTEFUqUgR1V6cur1Ex27f5xrG7`
- close digest: `F7Aao84uQWJxoXp2fpZme9pAyy8Twu19KjZjMADfXW5L`
- position ID: `0x7e9dc2d50daa28eae52f6da6bbaac8d510ebe7a432e5f3b070211529dce65402`

What it proves:

- the repo can execute against real Cetus shared objects on testnet
- package-matched object IDs are validated, not guessed

What it does not prove:

- core `cycle()` already manages live LP add / remove / close by itself

### 4) Shared vault holding a real Cetus `Position`

- archived report: `out/reports/cetus_vault_live_20260307T0829Z.json`
- manifest: `out/deployments/testnet_cetus_vault_live.json`
- package: `0xf2ef4141ad2cbe0de13ee528f5475b65308297eb0713de586bb9b30a49c8012e`
- open digest: `FMN7VDYxp3f5Sdr2Lr1jpGpJvP9yZz5zLhoJSTU7qSu6`
- close digest: `Cwda6DUMFZWFbDmgwk2X5TPr9kzkX4q4RjL9phGLDTuz`
- position ID: `0xd9e74bd36f93685fa862b952c734ce59decfd1fe993fc2d46ef2c83509af8d98`

What it proves:

- a shared vault can hold a real Cetus `Position` NFT across transactions
- the vault can later release and close it

What it does not prove:

- `cycle()` is not yet a fully automated live LP state machine

### 5) Queue-pressure `cycle_live` close-before-cycle proof

- archived report: `out/reports/cetus_cycle_live_probe_20260308T075620Z.json`
- package: `0x179c80eb1431016796e4bc9ce62f6da22fc151189b0964e26190f2f8ff0c7981`
- live tx digest: `3tjoD7afc5Qd1xiAmsF4kVa25Kj522JTZkkMG51fqSL3`

What it proves:

- under queue pressure, the live path can close the real Cetus position before `CycleEvent`
- the tx ended with `ready_usdc = treasury_usdc` and `deployed_usdc = 0`, which aligns real-object unwind with accounting state

### 6) Same-network operator-loop evidence

- archived report: `out/reports/testnet_same_network_autonomy_20260308T125512Z.json`
- continuation report: `out/reports/testnet_pressure_run_20260308T130434Z.json`

What it proves:

- planner-driven cycles can coexist with a real vault-held LP position
- queued withdrawal pressure can close a live Cetus position and continue cycling on testnet

### 7) Native staking proof

- archived report: `out/reports/sui_staking_probe_20260307T_manual.json`
- digest: `8QgfS7YQRq1bX2Dq9esLcC8CWhvi2itiEQCeQdfmXfZu`
- `StakedSui` object: `0x4c310ceda6b01eb9fae12438cd78e622771cc88db505cb75040c04f9f6732478`

What it proves:

- the repo has a second real yield leg on testnet beyond LP proof

### 8) First real DeFi lending proof via Scallop

- archived report: `out/reports/scallop_supply_probe_20260307T120021Z.json`
- status: `ok`
- deposit digest: `DYpcPubA3cKSzUyDBR8tb5Qf4oUNPmJTB33wWZ7QzBvd`
- withdraw digest: `9jFt9AuxjrGn8EmN7mBp41wMbMbLARhtnPrHqcXWoZZA`

What it proves:

- one real DeFi lending `deposit -> query -> withdraw` flow completed
- the Scallop SDK wiring works in real execution for the active wallet

What it does not prove:

- `Scallop` should still be described as `proof + bridge`, not same-network autonomous vault execution

### 9) Explicit perps blocker record

- archived report: `out/reports/aftermath_perps_probe_20260307T_manual.json`
- current status: `blocked`
- blocker details:
  - `registry::create_account` abort code `19`
  - tested collaterals returned `0 markets`

What it proves:

- the perps blocker is explicit and reproducible

What it does not prove:

- there is still no live perps evidence, and it should not be marketed as if it exists

### 10) Formal and chaos assurance layers

- formal entrypoint: `bash scripts/formal_verify_wsl.sh -v`
- chaos entrypoint: `python scripts/chaos_phase1.py`
- current chaos matrix: `12` deterministic experiments
- current formal scope: helper / accounting / planner / reserve / restore slices under `formal/`

What it proves:

- the repo has explicit assurance layers beyond unit tests
- blockers and degraded paths are replayable rather than hand-waved

What it does not prove:

- current formal scope is not the same as full proof of all live shared-object paths

---

## Honest Current Boundaries

These statements are true:

- real protocol evidence exists
- P5 technical closure is complete
- the strongest live-object depth today is on the Cetus path
- native staking proof exists
- one real DeFi lending proof exists via Scallop

These statements are not honest yet:

- fully autonomous same-network execution across every live leg
- Scallop is already same-network autonomous vault execution
- perps is nearly done
- final immutable release is ready now

The cleanest current framing is:

```text
high-trust live strategy prototype
  -> moving toward release-disciplined execution product
```

---

## Release Status

This repo deliberately separates `P5 complete` from `release-ready`.

Current release truth:

```text
P5 technical closure = yes
final immutable release readiness = no
```

What is already done:

- deploy / bootstrap / monitor / demo scripts exist
- `config.seal()` is implemented as a release gate
- setter behavior after `seal()` is covered by fail-closed tests
- final release dry-run tooling exists

Dry-run artifacts:

- normalized release candidate manifest:
  - `out/deployments/testnet_same_network_autonomy_c_final_release_candidate.json`
- dry-run report:
  - `out/reports/final_release_dry_run_20260309T102134Z.json`

What still remains before a final immutable release claim:

- final publish candidate must be replayed in the intended release posture
- operator / wallet / `AdminCap` responsibility must be frozen into the final release archive
- final release sign-off must stay aligned with the current external guardrails

---

## Why Sui

Sui's object model is a particularly good fit for this design:

- shared `Vault`
- shared withdrawal `Queue`
- object-identity-sensitive live protocol integrations
- planner / executor / post-sync state-machine structure
- vault-held real protocol objects across transactions

This is why the project focuses on proving real object behavior instead of only simulating accounting flows.

---

## Validation Snapshot

Latest local validation on `2026-03-09`:

- `cd sui && sui move test --quiet` -> `170 / 170 PASS`
- `cd sui && sui move test --coverage && sui move coverage summary` -> `94.85%`
- `python scripts/chaos_phase1.py` -> green
- `wsl bash scripts/formal_verify_wsl.sh -v` -> green

Why the current coverage headline is still honest:

- an older `>= 95%` headline was reached earlier in the repo history
- the current truth after live-LP expansion is `94.85%`
- the README now keeps the latest verified number instead of reusing stale historical metrics

The important practical point:

- live integration evidence matters more than one raw percentage
- but the percentage still has to stay truthful

---

## Quickstart

Build and test:

```bash
cd sui
sui move build
sui move test
sui move test --coverage
sui move coverage summary
sui move test --statistics
```

Formal verification from WSL:

```bash
bash scripts/install_sui_prover_wsl.sh
bash scripts/formal_verify_wsl.sh -v
```

Deploy and smoke:

```bash
python scripts/deploy_sui.py --base-type 0x2::sui::SUI --min-cycle-interval-ms 0 --min-snapshot-interval-ms 0
python scripts/testnet_cycle_smoke.py --manifest out/deployments/testnet_smoke.json
python scripts/monitor_sui.py --manifest out/deployments/testnet_smoke.json
```

Live proof probes:

```bash
python scripts/cetus_live_probe.py --help
python scripts/cetus_cycle_live_probe.py --help
python scripts/cetus_live_suite.py --help
python scripts/sui_staking_probe.py --help
python scripts/scallop_supply_probe.py --help
python scripts/aftermath_perps_probe.py --help
```

Windows short-path workaround:

```powershell
subst X: "C:\AI Projects\Fun Stuff\IndieHacker\Self-Driving-Yield-Sui"
$env:MOVE_HOME='X:\m'
cd X:\sui
sui move test
subst X: /D
```

---

## Repository Layout

```text
sui/
├─ Move.toml
├─ sources/
│  ├─ entrypoints.move
│  ├─ vault.move
│  ├─ oracle.move
│  ├─ queue.move
│  ├─ config.move
│  └─ adapters/
└─ tests/

scripts/
├─ deploy_sui.py
├─ testnet_cycle_smoke.py
├─ monitor_sui.py
├─ cetus_live_probe.py
├─ cetus_cycle_live_probe.py
├─ cetus_live_suite.py
├─ sui_staking_probe.py
├─ scallop_supply_probe.py
└─ aftermath_perps_probe.py

formal/
out/      # local manifests / reports
docs/     # local diligence and release notes
```

---

## Reading Order For Diligence

If you only read one file, read this README.

If you want deeper detail after that:

- `ASSURANCE_BOARD.md`
- `docs/P5_CLOSURE.md`
- `docs/INVESTOR_STATUS_BRIEF.md`
- `docs/EVIDENCE_BOARD.md`
- `docs/EXTERNAL_GUARDRAILS.md`
- `docs/FINAL_RELEASE_RUNBOOK.md`

---

## Bottom Line

This repo is no longer a paper-only strategy design.

It already shows:

- strong local correctness
- real testnet lifecycle evidence
- real Cetus live-object evidence
- real vault-held Position evidence
- real queue-pressure close-before-cycle evidence
- native staking proof
- first real DeFi lending proof
- explicit blocker discipline where proof does not yet exist

The remaining gap is not "can this repo touch real protocols at all?"

The remaining gap is:

```text
turning proven live paths into a more productized,
release-disciplined execution state machine
```
