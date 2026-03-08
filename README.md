# Self-Driving Yield Engine (Sui Move)

<p align="center">
  <strong>Autonomous yield routing, queue-aware liquidity, and regime-driven risk control on Sui.</strong>
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=rdQyEShM0vs">
    <img src="https://img.shields.io/badge/Demo-Video-red?style=for-the-badge&logo=youtube" alt="Demo Video">
  </a>
  <img src="https://img.shields.io/badge/Platform-Sui%20Move-yellow?style=for-the-badge" alt="Platform">
  <img src="https://img.shields.io/badge/Stage-P5%20Live%20Integration-brightgreen?style=for-the-badge" alt="Stage">
  <img src="https://img.shields.io/badge/Sui%20Framework-testnet%20%40%204e8aa9e-blue?style=for-the-badge" alt="Sui Framework">
  <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="License">
</p>

---

## What This Project Does

`Self-Driving Yield` is a **generic Sui Move vault** that:

- accepts a base asset `Coin<BASE>`
- mints `SDYE` shares
- samples price snapshots and computes a volatility regime
- rebalances among LP / yield / hedge buckets
- processes queued withdrawals with bounded caller bounty
- degrades into `OnlyUnwind` during stress and restores only after safe cycles

In plain English:

```text
[Deposit BASE]
      |
      v
[Mint SDYE shares]
      |
      v
[Permissionless cycle()]
      |
      +--> [Read oracle snapshots]
      +--> [Pick regime: CALM / NORMAL / STORM]
      +--> [Reserve liquidity for withdrawals]
      +--> [Rebalance LP / Yield / Hedge]
      +--> [Pay bounded bounty]
      |
      v
[Users redeem instantly or via queue -> claim()]
```

---

## Why It Exists

Most on-chain vaults optimize only for yield. This one optimizes for **yield + liquidity + survivability**.

```text
                    +---------------------------+
                    |  Self-Driving Yield Vault |
                    +-------------+-------------+
                                  |
         +------------------------+------------------------+
         |                        |                        |
         v                        v                        v
 [Yield Seeking]           [Liquidity Safety]        [Risk Control]
 LP / lending / carry      queue reserve / unwind     regime + OnlyUnwind
```

---

## Core Flow

### 1) User Flow

```text
(User)
   |
   v
[deposit(BASE)] ---> [Vault treasury]
   |                      |
   |                      v
   |                [cycle() decides allocation]
   |                      |
   v                      v
[receive SDYE]      [LP / Yield / Hedge buckets]
   |
   v
[request_withdraw(SDYE)]
   |
   +--> treasury enough? ---- yes ---> [instant redeem]
   |
   no
   |
   v
[queue request] --> [cycle() unwinds] --> [claim(BASE)]
```

### 2) Regime Flow

```text
[Spot snapshots]
      |
      v
[Oracle TWAP + volatility]
      |
      v
{vol < 1% ?}
   | yes
   v
[CALM]
   |
   +--> LP 40% / Yield 57% / Buffer 3%
   |
   no
   |
   v
{vol < 3% ?}
   | yes
   v
[NORMAL]
   |
   +--> LP 60% / Yield 37% / Buffer 3%
   |
   no
   |
   v
[STORM]
   |
   +--> LP 80% / Yield 17% / Buffer 3%
```

### 3) Risk Mode Flow

```text
[Normal operation]
      |
      v
[Storm / deviation / safety trigger]
      |
      v
[OnlyUnwind]
      |
      +--> can reduce exposure
      +--> cannot re-risk
      |
      v
[Safe cycle #1]
      |
      v
[Still OnlyUnwind]
      |
      v
[Safe cycle #2]
      |
      v
[Restore Normal]
```

---

## Architecture

```text
                 +----------------------------------+
                 |     entrypoints::Vault<BASE>     |
                 |        (shared object)           |
                 +----------------+-----------------+
                                  |
          +-----------------------+------------------------+
          |                       |                        |
          v                       v                        v
+-------------------+   +-------------------+   +-------------------+
| vault::VaultState |   | oracle::Oracle    |   | queue::Withdrawal |
| assets / shares   |   | TWAP / regime     |   | pending / ready   |
| risk mode         |   | samples / vol     |   | locked shares     |
+---------+---------+   +---------+---------+   +---------+---------+
          |                       |                        |
          +-----------------------+------------------------+
                                  |
                                  v
                  +---------------+----------------+
                  |  adapters::cetus / lending /   |
                  |  perps / rebalancer (P2)       |
                  +---------------+----------------+
                                  |
                                  v
                    +-------------+-------------+
                    |  accounting buckets       |
                    |  LP / Yield / Hedge       |
                    +---------------------------+
```

---

## Module Map

| Module | Responsibility |
|---|---|
| `vault.move` | share accounting, treasury accounting, risk mode, cycle core |
| `oracle.move` | snapshots, TWAP, volatility regime |
| `queue.move` | FIFO withdrawal queue, ready reserve, ownership checks |
| `entrypoints.move` | shared-object entry surface for deposit / withdraw / claim / cycle |
| `config.move` | operator parameters, adapter IDs, seal switch, config-level event |
| `adapters/*.move` | accounting wrappers for Cetus / lending / perps / flash rebalance |
| `entrypoints.move` + `config.move` events | deposit / withdraw / claim / cycle / config-seal monitoring events |

---

## Current Status

```text
P1  Core modules + unit tests                  [DONE]
P2  Strategy orchestration + adapter accounting [DONE]
P3  Lifecycle + concurrency + safety tests      [DONE locally]
P4  Deployment readiness artifacts              [DONE]
P5  Live testnet integration                    [IN PROGRESS: smoke OK]
```

What is included now:

- `OnlyUnwind` restore gate with `2` safe cycles
- multi-user queue fairness and conservation tests
- config freeze support for deployment finalization
- event surface for monitoring and alerting
- deploy / monitor / demo scripts for operator workflows
- funded testnet smoke path completed with `deposit + 12 cycles`
- local Move validation now sits at `106/106 PASS` and `95.57%` overall coverage
- local Cetus wrapper tests now cover `open / add / remove / swap / amount` flows
- explicit live LP helper path now includes `open_position_into_vault / rebalance_live / close_stored_position_from_vault`
- `cetus_live` now also has a `cycle_live` path that can auto-close a stored live Position under stress / queue pressure when the operator passes the real pool objects
- vault now persists live Cetus metadata for `open -> hold snapshot -> close`
- a real `Scallop` supply probe script now exists: `python scripts/scallop_supply_probe.py --help`
- latest Scallop mainnet proof succeeded: `depositQuick -> query -> withdrawQuick` now has a real archived report under `out/reports/scallop_supply_probe_20260307T120021Z.json`
- vault now also has live yield metadata / bookkeeping hooks ready for a real lending leg
- `scripts/scallop_core_bridge.py` now provides the operator bridge for syncing a successful Scallop report back into Vault bookkeeping, while explicitly blocking unsafe cross-network syncs
- oracle volatility is now based on return-style EWMA instead of simple TWAP deviation
- reserve math now uses an explicit `reserve_target = max(queue, ratio, floor)` style model, and `monitor_sui.py` now prints reserve-derived fields (`q_score`, reserve target, deployable)
- a dedicated WSL formal suite now exists under `formal/`, and `bash scripts/formal_verify_wsl.sh -v` currently proves the core helper layer with `sui-prover`

What is still intentionally out of scope for this repo snapshot:

- full formalization of `cycle()` / live shared-object paths; the current formal suite focuses on the core helper / accounting layer under `formal/`
- one-click mainnet publish from CI without operator wallet / gas
- production-grade hosted dashboards / alert routing beyond the local scripts
- fully automated `cycle()`-managed live LP add / remove / close state machine

Quick external-reader docs:

- `docs/INVESTOR_STATUS_BRIEF.md`
- `docs/EVIDENCE_BOARD.md`
- `docs/RUNBOOK.md`

---

## Quickstart

### Build and test

```bash
cd sui
sui move build
sui move test
sui move test --coverage
sui move coverage summary
sui move test --statistics
```

### Formal verification (WSL)

Run from the repo root inside WSL:

```bash
bash scripts/install_sui_prover_wsl.sh
bash scripts/formal_verify_wsl.sh -v
```

Current formal scope:

- `formal/` proves the core helper / accounting layer
- current green areas include `oracle::compute_regime` + first-snapshot transition, `queue::claim_ready` + empty-queue `process_queue` slice, queue creation/enqueue accounting, reserve / queue-pressure math identities, share math, first-deposit accounting, cycle helper proofs (`apply_cycle_regime` / `compute_cycle_bounty`), one empty-state `vault::cycle()` wrapper proof, risk-mode restore/reset, and live-yield bookkeeping helpers
- `cycle()` and live shared-object paths are still intentionally outside the current formal boundary

### Chaos Phase 1 (local)

Run the local blocker / operator-safety harness:

```bash
python scripts/chaos_phase1.py
```

Current chaos scope:

- bridge blockers: `blocked_bad_report_status`, `blocked_cross_network`, `blocked_wrong_active_env`, `blocked_non_isolated_wallet_state`
- bridge happy-path bookkeeping sync replay
- smoke blocker: `blocked_no_testnet_gas`
- monitor degraded paths: no-events alert, RPC error, malformed JSON, stale-cycle age alert, `OnlyUnwind` / reserve-pressure alert surfacing, and `used_flash` info surfacing
- current local chaos suite: `12` deterministic experiments, all replayable without funded chain mutation

### CI assurance

The current CI workflow now runs three layers:

- `move-tests`: installs `sui` via `suiup` and runs `cd sui && sui move test`
- `formal`: runs `bash scripts/formal_verify_wsl.sh -v` equivalent on Linux CI
- `chaos`: runs `python scripts/chaos_phase1.py`

Cross-platform note:

- Linux CI is sensitive to Windows-style path separators inside checked-in Move lockfiles
- the repo now normalizes `sui/Move.lock` / `formal/Move.lock` paths in CI before running tests, which prevents the recurring `packages\\...` dependency-resolution failure on Ubuntu runners

### Windows short-path helper

If your Windows path is too long for Move dependencies:

```powershell
subst X: "C:\AI Projects\Fun Stuff\IndieHacker\Self-Driving-Yield-Sui"
$env:MOVE_HOME='X:\m'
cd X:\sui
sui move test
subst X: /D
```

---

## Deployment Readiness (P4)

### P4.1 Params Frozen

`config.move` now supports a **freeze switch**.

```text
[Create Config]
      |
      v
[Set intervals + adapter IDs]
      |
      v
[seal(AdminCap)]
      |
      v
[All future setters abort]
```

Why this matters:

- makes final operator intent explicit
- prevents accidental config drift after launch
- gives monitoring a strong ?deployment finalized? signal

### P4.2 One-Click Deploy + Init

Use the deploy script:

```bash
python scripts/deploy_sui.py --help
python scripts/cetus_live_probe.py --help
```

Typical flow:

```text
[Publish package]
      |
      v
[Find SDYE TreasuryCap]
      |
      v
[bootstrap<BASE>()]
      |
      +--> create Vault shared object
      +--> create Queue shared object
      +--> create Config shared object
      +--> transfer AdminCap to operator
      |
      v
[Set adapter IDs]
      |
      v
[Freeze config]
      |
      v
[Write manifest JSON to out/deployments/*.json]
```

Example:

```bash
python scripts/deploy_sui.py   --base-type 0xdba34672e30...::usdc::USDC   --min-cycle-interval-ms 60000   --min-snapshot-interval-ms 60000   --cetus-pool-id 0x111   --lending-market-id 0x222   --perps-market-id 0x333   --flashloan-provider-id 0x444
```

### P4.3 Monitoring + Alerts

Use the monitoring script:

```bash
python scripts/monitor_sui.py --help
```

Event stream:

```text
[deposit()] ----------> DepositEvent
[request_withdraw()] -> WithdrawRequestedEvent
[claim()] ------------> ClaimedEvent
[cycle()] ------------> CycleEvent
[seal()] -------------> ConfigFrozenEvent
```

Alert logic:

```text
[Latest CycleEvent]
      |
      +--> OnlyUnwind == true          -> HIGH
      +--> ready_usdc > treasury       -> CRIT
      +--> pending_usdc > treasury     -> WARN
      +--> no cycle for too long       -> HIGH
      +--> used_flash == true          -> INFO
```

### P4.4 Ops Runbook (Minimal)

```text
If queue pressure rises:
  1. inspect latest CycleEvent
  2. compare treasury_usdc vs ready_usdc vs pending_usdc
  3. call cycle() again if interval allows
  4. if OnlyUnwind is active, do not attempt re-risking

If regime is storm:
  1. expect lower LP exposure
  2. expect unwind-first behavior
  3. watch safe_cycles_since_storm until restore

If flash path appears repeatedly:
  1. inspect delta size and queue load
  2. verify adapter IDs and liquidity assumptions
  3. consider widening cycle cadence or buffer policy
```

### P4.5 5-Minute Demo Script

Use the demo automation:

```bash
python scripts/demo_sui.py --help
```

Demo flow:

```text
[split base coin]
      |
      v
[deposit]
      |
      v
[cycle #1 -> deploy]
      |
      v
[request_withdraw]
      |
      v
[cycle #2 -> unwind queue]
      |
      v
[claim]
```

### P4.6 Mainnet Deploy

This repo now includes the artifacts needed for operator-driven mainnet deployment, but **actual publish still requires**:

- funded mainnet wallet
- finalized adapter IDs
- real `Coin<BASE>` choice
- operator confirmation of gas budgets and permissions

In other words: the repo is **deployment-ready**, but the final mainnet transaction is still an operator action.

---

## Testing Snapshot

Latest local validation after the coverage + wrapper sprint:

- `sui move test` -> `84/84 PASS`
- `sui move coverage summary` -> `95.60%` overall
- key module snapshot -> `entrypoints 95.72%`, `queue 96.34%`, `oracle 95.44%`, `vault 93.89%`, `cetus_amm 88.63%`
- live-integration risk still matters more than raw local coverage, especially around real shared objects and operator flows
- latest live testnet validation on `2026-03-07`: `testnet_cycle_smoke.py --manifest out/deployments/testnet_smoke.json` returned `status=ok`, completed another `deposit + 12 cycles`, and `monitor_sui.py` reported `OK: no alert thresholds triggered`

Coverage progress from this sprint:

| Area | Before | After |
|---|---:|---:|
| Total coverage | 92.91% | 95.60% |
| Total tests | 73 | 84 |
| `entrypoints` | 90.87% | 95.72% |
| `queue` | 92.39% | 96.34% |
| `oracle` | 91.23% | 95.44% |
| `vault` | 93.26% | 93.89% |
| `cetus_amm` | 88.63% | 88.63% |

Testing pyramid used in this repo:

```text
           /          /P4\      Deploy scripts / monitoring / demo readiness
         /----        / P3  \    Lifecycle / invariants / concurrency tests
       /------      /  P2    \   test_scenario integration flows
     /--------    /   P1     \  unit tests per module
   /----------  /    P0      \ research / interfaces / economics
```

---

## Upgrade Strategy

What matters now:

- The repo is currently a **single Sui package**, so upgradeability is decided at the package level, not per module.
- That means `immutable core + timelocked adapters` is a good target architecture, but it is **not fully achievable in the current package layout**.

Recommended decision:

```text
[Current single-package layout]
      |
      +--> v1 recommendation: publish immutable after P5 sign-off
      |
      +--> if future adapter churn is expected:
              split adapters into a separate package first
              then keep core immutable + adapters behind timelock
```

### P5.1 Cetus-First Live Probe

For the first real external-object slice, use the dedicated live probe:

```bash
python scripts/cetus_live_probe.py --help
python scripts/cetus_live_suite.py --help
python scripts/sui_staking_probe.py --help
```

What it does:

- creates or refreshes a dedicated manifest such as `out/deployments/testnet_cetus_live.json`
- pins a real non-zero `cetus_pool_id` into config during deploy
- opens a real Cetus position with user-supplied coins against real shared objects
- optionally closes the position immediately and archives a JSON report under `out/reports/`

Latest real-object proof on `2026-03-07`:

- real `TEST_QUOTE / SDYE` Cetus pool created on testnet: `0xe8bee419df59bf9b71666255e3956ad8e324b03f39a2c413f174cb157fd84cd8`
- `cetus_live_probe.py` completed `open -> close` successfully against that pool
- probe digests: open `DEcDuiCYaxZ1um1CTZ6eknB1iCZbcJixVpJfo5vXZHqZ`, close `6D61T4sevFafRGpBCnd5D3buruPzrGm2zoJWvCroQhs3`
- one-click replay now exists: `python scripts/cetus_live_suite.py --help`
- result: the repo now has current testnet evidence for a real external-object Cetus path, not only accounting-only lifecycle smoke

Latest vault-ownership proof on `2026-03-07`:

- fresh vault-live package: `0xf2ef4141ad2cbe0de13ee528f5475b65308297eb0713de586bb9b30a49c8012e`
- `open_position_into_vault_entry` digest: `FMN7VDYxp3f5Sdr2Lr1jpGpJvP9yZz5zLhoJSTU7qSu6`
- `close_stored_position_from_vault_entry` digest: `Cwda6DUMFZWFbDmgwk2X5TPr9kzkX4q4RjL9phGLDTuz`
- what this proves: a shared `Vault` can now hold a real Cetus `Position` NFT across transactions and release it later

Latest yield-source proof on `2026-03-07`:

- native testnet staking probe script: `python scripts/sui_staking_probe.py --help`
- latest successful staking digest: `8QgfS7YQRq1bX2Dq9esLcC8CWhvi2itiEQCeQdfmXfZu`
- latest `StakedSui` object: `0x4c310ceda6b01eb9fae12438cd78e622771cc88db505cb75040c04f9f6732478`
- why this matters: the repo now has a second real yield leg on testnet, even though `yield_source.move` itself is still accounting-only in core Move logic

Perps testnet note:

- `python scripts/aftermath_perps_probe.py --help` archives the current Aftermath perps blocker
- latest run hit `registry::create_account` abort code `19`, and tested collaterals returned zero markets
- treat perps testnet as blocked until Aftermath re-enables or documents a working testnet path

Accounting branch vs live branch:

```text
[Accounting branch]
   ├─ uses plain `cycle()`
   ├─ rebalances internal buckets only
   └─ proves vault / queue / oracle / accounting lifecycle

[Live branch]
   ├─ uses Cetus live helpers and real shared objects
   ├─ explicit paths: `open_position_into_vault / rebalance_live / close_stored_position_from_vault`
   ├─ vault tracks live Position metadata across tx
   └─ current limit: `rebalance_live` records live hold snapshots, but does not yet auto add/remove/close liquidity
```

Why this matters:

- it produces evidence beyond the accounting-only `cycle()` path
- it keeps real Cetus proof separate from the older lifecycle-only `testnet_smoke` manifest
- it also exposed an integration gotcha: this repo is pinned to Cetus testnet package `0x5372...`, so live object IDs must match that package rather than older SDK defaults

Why this is the safest default:

- `vault / queue / oracle / share accounting` carry the highest invariant risk.
- keeping the whole package upgradeable just to patch adapters leaves the core mutable too.
- if adapter flexibility is genuinely needed, package split is the clean boundary.
- `config.seal()` should still be part of the launch path even for an immutable release.

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
├─ backtest.py
├─ cetus_live_probe.py
├─ deploy_sui.py
├─ monitor_sui.py
└─ demo_sui.py

poc/
out/                  # local manifests / generated artifacts (gitignored)
```

---

## Notes on Legacy Files

Some ignored root-level documents are from an older BSC / Solidity exploration and are **not** the source of truth for the current Sui Move implementation.

Use this README + `sui/` source code as the primary reference.

---

## Next Logical Steps

If you want to keep shipping after P4, the next high-value items are:

```text
[P5 Live Integration]
   |
   +--> upgrade `rebalance_live` from hold-snapshot to true add/remove/close state machine
   +--> add one real DeFi yield leg beyond native staking (Scallop first)
   +--> keep investor evidence board + README in sync with the latest reports
   +--> operator dashboard / hosted alerting
```


