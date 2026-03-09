# Self-Driving Yield Engine (Sui Move)

<p align="center">
  <strong>Queue-aware, regime-driven treasury execution on Sui with real protocol evidence.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-Sui%20Move-yellow?style=for-the-badge" alt="Platform">
  <img src="https://img.shields.io/badge/Stage-P5%20Technical%20Closure-brightgreen?style=for-the-badge" alt="Stage">
  <img src="https://img.shields.io/badge/Release-Final%20Immutable%20Ready-brightgreen?style=for-the-badge" alt="Release">
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
- a sealed final release candidate with non-zero Cetus + lending adapter IDs
- same-package live evidence replayed on that sealed final candidate

The honest current conclusion is:

```text
P5 technical closure = yes
final immutable release readiness = yes
```

This is enough for technical diligence, investor conversations, and a truthful final immutable release-readiness claim on testnet.
It is still not honest to present the repo as fully autonomous across every live leg or as having live perps execution today.

---

## For Non-Technical Readers

If you do not read Move code, the simplest explanation is:

```text
This project is trying to turn idle onchain treasury capital
into a risk-managed yield engine.

It does not just chase yield.
It also protects withdrawal liquidity,
reduces risk during stress,
and leaves an evidence trail for what has truly been proven.
```

What makes this different from a normal yield strategy deck:

- it already has real protocol execution evidence, not just simulations
- it has an explicit safety mode called `OnlyUnwind`
- it has a sealed release artifact, so the final testnet release is not a moving target
- it uses formal verification and chaos engineering to check failure behavior, not only happy paths

In plain language:

- `formal verification` means mathematically checking critical rules so certain accounting and safety properties cannot silently drift
- `chaos engineering` means deliberately forcing bad conditions to verify the system fails in controlled, observable ways

---

## Investor Readiness

Current external positioning:

```text
sealed testnet release candidate
with real LP + yield evidence
and explicit operational boundaries
```

Why this positioning is already defensible:

- the repo is no longer a design-only strategy doc
- there is a sealed final candidate on testnet
- there is real Cetus live-object evidence
- there is real native staking evidence
- there is one real DeFi lending proof via Scallop
- there is explicit release discipline, archive discipline, and operator tooling

What should not be implied:

- fully autonomous across every live leg
- mainnet-ready launch next week
- perps is already live
- every adapter is already same-network automated

Recommended diligence summary:

```text
We already proved the hard part:
this vault can survive real object-level execution,
queue pressure, and sealed-release discipline on Sui testnet.

The remaining work is productization and operational depth,
not whether the system can touch real protocols at all.
```

---

## For Technical Readers

If you are technical, the repo should be read as:

```text
shared-object vault
  + FIFO withdrawal queue
  + regime-aware reserve logic
  + sealed config gate
  + real-object LP / yield probes
  + operator tooling around a testnet final candidate
```

The key technical claim is not "we wrote a vault."

The key technical claim is:

```text
the vault logic,
the release discipline,
and the evidence archive
have all been exercised together
on a sealed candidate
with honest boundary statements
```

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
| `R1` final immutable release closure | `DONE` | sealed final candidate + same-package live evidence + ready dry-run are archived |

The strongest honest one-liner today is:

> We now have a sealed final release candidate on testnet with real LP/yield evidence and a clean release-readiness archive.

---

## Evidence Ledger

This section is the single-page answer to: "What is actually proven right now?"

Before the itemized ledger, here is the credibility stack in one screen:

```text
[Local tests]
   -> prove broad functional correctness

[Formal verification]
   -> prove selected accounting / reserve / restore invariants

[Chaos engineering]
   -> prove degraded paths and operator blockers are observable and replayable

[Live testnet evidence]
   -> prove the system can touch real external objects and survive queue pressure

[Sealed release discipline]
   -> prove the final candidate is archived, frozen, and reviewable
```

### 1) Local correctness headline

- `170 / 170 PASS`
- `94.91%` overall Move coverage
- key module snapshot:
  - `oracle`: `99.61%`
  - `entrypoints`: `95.98%`
  - `queue`: `95.62%`
  - `yield_source`: `97.31%`
  - `vault`: `93.49%`
  - `cetus_live`: `89.67%`
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

- archived report: `out/reports/testnet_final_release_v2_pressure_20260309T1228Z.json`
- manifest: `out/deployments/testnet_final_release_v2.json`
- package: `0x76ae0e284176075cd0bda8f5b0fd86220ec15f9c21bdf9d02c3910367dca883b`
- sealed release candidate: `out/deployments/testnet_final_release_v2_final_release_candidate.json`
- live tx digest: `d5aUyuuNt5W6y6NRXdsrXVMMbrhhQLe117udiEm5pRX`
- real pool: `0x0b5b1a1bd56f39bb817b194682516dcae4ac0ad7aa5f0fa6af403e909c3e89bd`
- closed position ID: `0x97b5cd753ada1beca04591ab95254cac3b3e2d800846336a7357ce8241587331`

What it proves:

- on the sealed final package, queued withdrawals can still force the live path to close the stored real Cetus position before `CycleEvent`
- the replay ended with `close_event_index = 2` and `cycle_event_index = 4`, so the unwind really happened before accounting finalization
- two withdraws were queued in the recorded run, not just simulated locally

### 6) Same-network operator-loop evidence

- archived report: `out/reports/testnet_final_release_v2_same_network_20260309T1214Z.json`
- package: `0x76ae0e284176075cd0bda8f5b0fd86220ec15f9c21bdf9d02c3910367dca883b`
- manifest: `out/deployments/testnet_final_release_v2.json`
- same-package `StakedSui` sync digests:
  - `sync_live_yield_deposit_entry`: `8YU9rSHPzJ7c9VenUyHxR3USJ36Vnzciqa1enXhfQa55`
  - `sync_live_yield_hold_entry`: `4wof5bJhkRNDSxtRQFUBmS5mmRUzwGCTmvVFTc3cvZbz`
  - planner / cycle replay: `CPbmnoyoasqLWB4oxKzVd5JnTkKToxbYq1bquq9BpEL1`

What it proves:

- on the sealed final package, planner-driven cycles can coexist with a real vault-held LP position and a real native staking receipt
- the planner saw a live Cetus position, live yield metadata, and non-zero queue pressure in the same replay

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
- current chaos matrix: `16` deterministic experiments
- current formal scope: helper / accounting / planner / reserve / restore slices under `formal/`

What it proves:

- the repo has explicit assurance layers beyond unit tests
- blockers and degraded paths are replayable rather than hand-waved
- critical accounting and reserve rules are not validated only by sample scenarios; selected invariants are machine-checked
- operator failure modes are intentionally rehearsed, including no-events, RPC errors, malformed JSON, stale cycles, queue pressure, low gas, and external price-source paths

What it does not prove:

- current formal scope is not the same as full proof of all live shared-object paths

Why this matters for diligence:

- many early-stage vaults have backtests and happy-path demos
- fewer have formal proofs for core accounting slices
- fewer still have a maintained chaos harness that deliberately exercises failure reporting and operator blockers

That is why the assurance story here should be presented as:

```text
not just "we tested it"
but "we tested it, proved selected invariants,
and rehearsed failure conditions"
```

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

The cleanest current framing is:

```text
sealed testnet release candidate
  -> real LP + yield evidence
  -> explicit guardrails around what is still operator-mediated
```

---

## Release Status

This repo deliberately separates `P5 complete` from `release-ready`.

Current release truth:

```text
P5 technical closure = yes
final immutable release readiness = yes
```

What is already done:

- deploy / bootstrap / monitor / demo scripts exist
- `config.seal()` is implemented as a release gate
- setter behavior after `seal()` is covered by fail-closed tests
- final publish candidate is sealed with non-zero `cetus_pool_id` and non-zero `lending_market_id`
- same-package live evidence was replayed on the sealed candidate
- final release dry-run passed with a clean git worktree

Final release artifacts:

- sealed source manifest:
  - `out/deployments/testnet_final_release_v2.json`
- normalized release candidate manifest:
  - `out/deployments/testnet_final_release_v2_final_release_candidate.json`
- dry-run report:
  - `out/reports/final_release_dry_run_20260309T1232Z.json`

What this final immutable release claim means:

- the release artifact is sealed and archived
- the release artifact has live LP and live yield evidence on the same package
- the claim is about immutable release discipline on testnet, not about every future adapter being fully autonomous

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
- `cd sui && sui move test --coverage && sui move coverage summary` -> `94.91%`
- `python scripts/chaos_phase1.py` -> green
- `wsl bash scripts/formal_verify_wsl.sh -v` -> green

Why the current coverage headline is still honest:

- an older `>= 95%` headline was reached earlier in the repo history
- the current truth after the latest verification is `94.91%`
- the README now keeps the latest verified number instead of reusing stale historical metrics

The important practical point:

- live integration evidence matters more than one raw percentage
- but the percentage still has to stay truthful

Assurance headline for mixed audiences:

- unit / integration coverage gives breadth
- formal verification gives invariant depth
- chaos engineering gives operational failure realism
- live probes give real protocol contact

Together, these four layers are the reason the README can support investor diligence instead of reading like a pure roadmap.

---

## Operator Ops Layer

The sealed release artifact is now complemented by a non-invasive ops layer under `scripts/`.

These scripts do not mutate the published Move package and do not reopen release closure by themselves.

They exist to make operation, diligence handoff, and queue-pressure response more concrete:

- `python scripts/monitor_sui.py --manifest out/deployments/testnet_final_release_v2.json --json`
  - emits structured `severity`, `action_hint`, `queue_pressure_bps`, `reserve_gap_usdc`, and `stale_cycle_minutes`
- `python scripts/keeper_daemon.py --manifest out/deployments/testnet_final_release_v2.json --once --spot-price 1000000000`
  - polls the structured monitor payload, applies local lockfile + gas checks, and decides whether `cycle_entry` or `cycle_live_entry` would be triggered
  - default mode is dry-run; add `--execute` only when the operator intends to submit real transactions
- `python scripts/fetch_spot_price.py --source coingecko --coingecko-id sui`
  - fetches a normalized keeper-ready integer spot price from `CoinGecko`, `Binance`, or a custom HTTP JSON endpoint
- `python scripts/keeper_daemon.py --manifest out/deployments/testnet_final_release_v2.json --once --price-source coingecko --coingecko-id sui`
  - lets the keeper use an external price feed instead of a hand-entered `--spot-price`
- `python scripts/reserve_policy_replay.py --json`
  - replays the current reserve policy against synthetic pressure scenarios without touching chain state
- `python scripts/export_audit_bundle.py --zip`
  - copies the current manifest, reports, and diligence docs into one local audit bundle with hashes

What this means:

- the sealed package remains unchanged
- operator liveness and evidence export are now less ad hoc
- investor / auditor handoff no longer depends on manually collecting files one by one

Current operational note as of `2026-03-09`:

- external HTTP price sources are now wired into the keeper ops layer
- keeper dry-run works against the sealed final manifest
- the next real keeper execution is currently waiting on refreshed `testnet` gas, not on missing code

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
python scripts/monitor_sui.py --manifest out/deployments/testnet_final_release_v2.json --json
python scripts/keeper_daemon.py --manifest out/deployments/testnet_final_release_v2.json --once --spot-price 1000000000
python scripts/fetch_spot_price.py --source coingecko --coingecko-id sui
python scripts/keeper_daemon.py --manifest out/deployments/testnet_final_release_v2.json --once --price-source coingecko --coingecko-id sui
python scripts/reserve_policy_replay.py --json
python scripts/export_audit_bundle.py --zip
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
├─ fetch_spot_price.py
├─ keeper_daemon.py
├─ reserve_policy_replay.py
├─ export_audit_bundle.py
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

Suggested reading by audience:

- non-technical investor
  - this README
  - `docs/INVESTOR_STATUS_BRIEF.md`
- technical investor / auditor
  - this README
  - `ASSURANCE_BOARD.md`
  - `docs/EVIDENCE_BOARD.md`
  - `docs/P5_CLOSURE.md`
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
