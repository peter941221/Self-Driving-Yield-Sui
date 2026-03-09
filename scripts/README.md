# Scripts Directory

This directory contains the executable operator, deployment, evidence, and assurance helpers for the public repo.

It should be read as the runtime/tooling layer around the Move package in `sui/`.

## What Lives Here

- deployment and dry-run helpers
  - `deploy_sui.py`
  - `final_release_dry_run.py`
- live evidence probes
  - `cetus_live_probe.py`
  - `cetus_cycle_live_probe.py`
  - `cetus_live_suite.py`
  - `sui_staking_probe.py`
  - `scallop_supply_probe.py`
  - `aftermath_perps_probe.py`
- operator tooling
  - `monitor_sui.py`
  - `keeper_daemon.py`
  - `fetch_spot_price.py`
  - `reserve_policy_replay.py`
  - `export_audit_bundle.py`
- local assurance / replay
  - `chaos_phase1.py`
  - `testnet_cycle_smoke.py`
  - `testnet_pressure_run.py`
  - `testnet_same_network_autonomy.py`

## Suggested Entry Points

- first read for ops: `monitor_sui.py`
- first read for automation: `keeper_daemon.py`
- first read for investor/audit handoff: `export_audit_bundle.py`
- first read for live LP evidence: `cetus_cycle_live_probe.py`
- first read for local failure rehearsal: `chaos_phase1.py`

## Typical Commands

```bash
python scripts/monitor_sui.py --manifest out/deployments/testnet_final_release_v2.json --json
python scripts/keeper_daemon.py --manifest out/deployments/testnet_final_release_v2.json --once --price-source coingecko --coingecko-id sui
python scripts/reserve_policy_replay.py --json
python scripts/export_audit_bundle.py --zip
python scripts/chaos_phase1.py
```

## Boundary

These scripts strengthen operation and evidence handling.

They do not change the sealed Move package by themselves.

Any edit under `sui/` is a different class of change and can invalidate the current sealed release claim.
