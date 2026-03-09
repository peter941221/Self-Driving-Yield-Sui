# Assurance Board

This file is the tracked, public-facing summary of what the repo currently proves, tests, and stress-checks.

Last verified: `2026-03-09`

## Snapshot

- Move unit/scenario suite: green locally (`170/170 PASS`)
- Formal suite: green under WSL/Linux runner
- Chaos Phase 1: green locally
- CI pipeline: `move-tests` + `formal` + `chaos`
- Current delivery phase: `P4 done -> P5 live testnet integration`
- Current local coverage headline: `94.85%`

## Formal Layer

- Package: `formal/`
- Runner: `bash scripts/formal_verify_wsl.sh -v`
- Current green scope: `50` proof entrypoints
- Highlights:
  - regime classification
  - first-snapshot transition
  - queue reserve accounting slices
  - adjusted-buffer cap boundaries
  - planner action / live-close intent helpers
  - reserve-floor / queue-pressure helper math
  - share math
  - first-deposit accounting
  - cycle helper slices + one empty-state `vault::cycle()` wrapper slice
  - zero-edge bounty identities
  - yield bookkeeping helpers

See also:

- `formal/PROOF_MATRIX.md`

## P5 Live Status

- Current strongest live evidence:
  - native lifecycle smoke on testnet
  - native staking proof on testnet
  - Scallop supply / withdraw proof on mainnet via split-network proof + bridge flow
  - Cetus real-object `open -> close` proof on testnet
  - vault-held Cetus Position ownership across transactions on testnet
  - queue-pressure `cycle_live` proof that closes the live Position before `CycleEvent`
  - same-network testnet operator loop proving planner-driven `cycle()` + real vault-held Cetus live position + real native staking yield sync on one network
  - real pressure run proving queued withdrawal pressure can close a live Cetus position and continue cycling without failed tx evidence in the recorded run
- Latest `cycle_live` evidence:
  - manifest: `out/deployments/testnet_cetus_cycle_live.json`
  - report: `out/reports/cetus_cycle_live_probe_20260308T075620Z.json`
  - tx digest: `3tjoD7afc5Qd1xiAmsF4kVa25Kj522JTZkkMG51fqSL3`
  - key result: `CetusPositionClosedEvent` index `2` landed before `CycleEvent` index `3`
- Latest same-network autonomy evidence:
  - manifest: `out/deployments/testnet_same_network_autonomy_c.json`
  - report: `out/reports/testnet_same_network_autonomy_20260308T125512Z.json`
  - key result: one testnet operator loop synced an existing real `StakedSui` receipt into vault live-yield bookkeeping, then a planner-driven `cycle()` emitted `StrategyPlannedEvent` with both `live_cetus_position_present = true` and `live_yield_position_present = true`
- Latest pressure evidence:
  - manifest: `out/deployments/testnet_same_network_autonomy_c.json`
  - report: `out/reports/testnet_pressure_run_20260308T130434Z.json`
  - key result: queued withdrawal tx `Hc8PJBj84gzh4T3Bq9wVHPJQ6WVvtHxsGnMbzCnydNHC` followed by live pressure tx `HkYqBFYVa5WfCn41U2jMJLMZDRhppnSf4Fv8d86Q1JA4`, where `CetusPositionClosedEvent` landed before `CycleEvent` and the run continued with four more green `cycle()` calls
- Remaining P5 gaps:
  - `vault::cycle()` now has a unified planner and same-network operator-loop evidence, but direct same-tx native execution of every live leg still depends on protocol-specific runtime entrypoints
  - live adapter depth is still strongest on Cetus + native staking bookkeeping; external lending/perps remain shallower
  - Scallop is still real yield evidence, but not same-network vault execution
  - Aftermath perps remains blocked on testnet and is not a sign-off-quality live leg yet

## External Narrative Guardrail

- What this board proves:
  - the repo has real archived live evidence beyond local tests
  - the repo has stronger LP/live-object depth than an accounting-only prototype
  - the repo now has confidence-aware risk and guarded restore logic in core state transitions
  - the repo can support `P5 technical sign-off discussion`
- What this board does NOT prove:
  - final immutable release readiness
  - fully autonomous same-network execution across every live leg
  - a working Aftermath perps leg on testnet

## Chaos Layer

- Runner: `python scripts/chaos_phase1.py`
- Current green scope: `12` deterministic local experiments
- Highlights:
  - Scallop bridge blocker statuses
  - bridge happy-path replay
  - smoke `blocked_no_testnet_gas`
  - monitor no-events / RPC error / malformed JSON
  - stale-cycle alert
  - `OnlyUnwind` / reserve-pressure alert surfacing
  - `used_flash` info surfacing

See also:

- `CHAOS_MATRIX.md`

## CI Layer

- Workflow: `.github/workflows/formal.yml`
- Jobs:
  - `move-tests`
  - `formal`
  - `chaos`
- Current Linux CI hardening:
  - installs `sui` via `suiup`
  - normalizes Move lockfile path separators before test execution
  - uploads `formal-log` and `chaos-reports` artifacts

## Deferred

- `vault::cycle()` full multi-phase state-machine proof
- stronger generalized `process_queue()` progress/FIFO proof
- richer `record_snapshot_with_ts()` post-state proof beyond first-snapshot slice
- live shared-object formal proofs
- chaos around live Cetus object mismatches and incomplete cycle-event evidence
