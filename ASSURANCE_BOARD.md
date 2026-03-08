# Assurance Board

This file is the tracked, public-facing summary of what the repo currently proves, tests, and stress-checks.

## Snapshot

- Move unit/scenario suite: green locally
- Formal suite: green under WSL/Linux runner
- Chaos Phase 1: green locally
- CI pipeline: `move-tests` + `formal` + `chaos`

## Formal Layer

- Package: `formal/`
- Runner: `bash scripts/formal_verify_wsl.sh -v`
- Current green scope: `33` proof entrypoints
- Highlights:
  - regime classification
  - first-snapshot transition
  - queue reserve accounting slices
  - reserve-floor / queue-pressure helper math
  - share math
  - first-deposit accounting
  - cycle helper slices + one empty-state `vault::cycle()` wrapper slice
  - yield bookkeeping helpers

See also:

- `formal/PROOF_MATRIX.md`

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

