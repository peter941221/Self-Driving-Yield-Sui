# Formal Directory

This directory contains the public formal verification package for the repo.

Its job is not to prove every live protocol interaction.

Its job is to machine-check the highest-value accounting, reserve, planner, and restore invariants that justify the vault's core safety claims.

## What Lives Here

- `Move.toml`
  - standalone formal package definition
- `sources/*.move`
  - proof entrypoints grouped by subsystem
- `PROOF_MATRIX.md`
  - public map from proof entrypoints to the invariant they support

## Current Scope

The current public proof scope focuses on:

- oracle regime classification
- first snapshot transition behavior
- queue reserve accounting slices
- reserve and buffer helper math
- planner action helpers
- share math and first deposit accounting
- risk-mode restore / reset behavior
- bounded bounty identities
- yield bookkeeping helpers

## Run

```bash
bash scripts/install_sui_prover_wsl.sh
bash scripts/formal_verify_wsl.sh -v
```

## Boundary

This package is intentionally narrower than "full protocol correctness."

It does not yet prove:

- full `vault::cycle()` state-machine behavior
- live shared-object protocol flows
- cross-network runtime guarantees
- keeper liveness or external RPC assumptions
