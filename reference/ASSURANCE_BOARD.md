# Assurance Board

This file is the tracked, public-facing summary of what the repo currently proves, tests, and stress-checks.

Last verified: `2026-03-09`

## Snapshot

- Move unit/scenario suite: green locally (`170/170 PASS`)
- Formal suite: green under WSL/Linux runner
- Chaos Phase 1: green locally
- CI pipeline: `move-tests` + `formal` + `chaos`
- Current delivery phase: `P5 complete -> R1 sealed testnet release candidate archived`
- Current local coverage headline: `94.91%`

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
  - sealed final candidate replay proving planner-driven `cycle()` + real vault-held Cetus live position + real native staking yield sync on one package
  - sealed final pressure replay proving queued withdrawal pressure can close a live Cetus position before `CycleEvent`
- Latest sealed same-package evidence:
  - manifest: `out/deployments/testnet_final_release_v2.json`
  - report: `out/reports/testnet_final_release_v2_same_network_20260309T1214Z.json`
  - key result: one sealed package replay observed `live_cetus_position_present = true`, `live_yield_position_present = true`, and non-zero queue pressure together
- Latest sealed pressure evidence:
  - manifest: `out/deployments/testnet_final_release_v2.json`
  - report: `out/reports/testnet_final_release_v2_pressure_20260309T1228Z.json`
  - tx digest: `d5aUyuuNt5W6y6NRXdsrXVMMbrhhQLe117udiEm5pRX`
  - key result: `CetusPositionClosedEvent` landed before `CycleEvent` on the sealed candidate
- Remaining post-release gaps:
  - direct same-tx native execution of every live leg still depends on protocol-specific runtime entrypoints
  - live adapter depth is still strongest on Cetus + native staking bookkeeping; external lending/perps remain shallower
  - Scallop is still real yield evidence, but not same-network vault execution
  - Aftermath perps remains blocked on testnet and is not a sign-off-quality live leg yet

## External Narrative Guardrail

- What this board proves:
  - the repo has real archived live evidence beyond local tests
  - the repo has stronger LP/live-object depth than an accounting-only prototype
  - the repo now has confidence-aware risk and guarded restore logic in core state transitions
  - the repo can support technical diligence and a truthful sealed testnet release-readiness claim
- What this board does NOT prove:
  - fully autonomous same-network execution across every live leg
  - a working Aftermath perps leg on testnet
  - immediate mainnet launch readiness

## Chaos Layer

- Runner: `python scripts/chaos_phase1.py`
- Current green scope: `16` deterministic local experiments
- Highlights:
  - Scallop bridge blocker statuses
  - bridge happy-path replay
  - smoke `blocked_no_testnet_gas`
  - monitor no-events / RPC error / malformed JSON
  - stale-cycle alert
  - `OnlyUnwind` / reserve-pressure alert surfacing
  - `used_flash` info surfacing
  - structured monitor JSON payload validation
  - keeper low-gas dry-run blocking
  - standalone external price fetch normalization
  - keeper external-price dry-run readiness

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
