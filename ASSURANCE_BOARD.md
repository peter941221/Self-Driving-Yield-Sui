# Assurance Board

This file is the tracked, public-facing summary of what the repo currently proves, tests, and stress-checks.

## Snapshot

- Move unit/scenario suite: green locally
- Formal suite: green under WSL/Linux runner
- Chaos Phase 1: green locally
- CI pipeline: `move-tests` + `formal` + `chaos`
- Current delivery phase: `P4 done -> P5 live testnet integration`

## Formal Layer

- Package: `formal/`
- Runner: `bash scripts/formal_verify_wsl.sh -v`
- Current green scope: `37` proof entrypoints
- Highlights:
  - regime classification
  - first-snapshot transition
  - queue reserve accounting slices
  - adjusted-buffer cap boundaries
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
  - Scallop supply / withdraw proof on testnet
  - Cetus real-object `open -> close` proof on testnet
  - vault-held Cetus Position ownership across transactions on testnet
  - queue-pressure `cycle_live` proof that closes the live Position before `CycleEvent`
- Latest `cycle_live` evidence:
  - manifest: `out/deployments/testnet_cetus_cycle_live.json`
  - report: `out/reports/cetus_cycle_live_probe_20260308T075620Z.json`
  - tx digest: `3tjoD7afc5Qd1xiAmsF4kVa25Kj522JTZkkMG51fqSL3`
  - key result: `CetusPositionClosedEvent` index `2` landed before `CycleEvent` index `3`
- Remaining P5 gaps:
  - `vault::cycle()` is still not a full live multi-adapter strategy engine
  - live adapter depth is still strongest on Cetus; other live legs are shallower
  - Aftermath perps remains blocked on testnet and is not a sign-off-quality live leg yet

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
