# Chaos Matrix

This matrix summarizes the current local `scripts/chaos_phase1.py` suite.

## Scope

- Runner: `python scripts/chaos_phase1.py`
- Current style: local deterministic fault injection
- No funded chain mutation required
- Main focus: operator blockers, report discipline, and monitor false-green prevention

## Matrix

| Experiment | Target | Injection | Expected Safe Outcome |
|---|---|---|---|
| `bridge_blocked_bad_report_status` | `scallop_core_bridge.py` | source report `status != ok` | exits with `blocked_bad_report_status` and writes blocker report |
| `bridge_blocked_cross_network` | `scallop_core_bridge.py` | report env != manifest network | exits with `blocked_cross_network` |
| `bridge_blocked_wrong_active_env` | `scallop_core_bridge.py` | fake CLI returns wrong active env | exits with `blocked_wrong_active_env` |
| `bridge_blocked_non_isolated_wallet_state` | `scallop_core_bridge.py` | source report has pre-existing lending value | exits with `blocked_non_isolated_wallet_state` |
| `bridge_ok_happy_path` | `scallop_core_bridge.py` | fake CLI returns successful `call` payloads | writes `status = ok` with three sync steps |
| `smoke_blocked_no_testnet_gas` | `testnet_cycle_smoke.py` | fake CLI returns empty gas payload | exits with `blocked_no_testnet_gas` |
| `monitor_no_events` | `monitor_sui.py` | RPC returns zero events | exits non-zero with `ALERT: no events found` |
| `monitor_rpc_error` | `monitor_sui.py` | RPC returns explicit JSON-RPC error | exits non-zero and never prints `OK` |
| `monitor_malformed_json` | `monitor_sui.py` | RPC returns invalid JSON body | exits non-zero and never prints `OK` |
| `monitor_only_unwind_pressure` | `monitor_sui.py` | synthetic `CycleEvent` with `OnlyUnwind` + queue pressure | surfaces HIGH/CRIT/WARN alerts |
| `monitor_stale_cycle` | `monitor_sui.py` | synthetic stale `CycleEvent` timestamp | surfaces stale-cycle HIGH alert |
| `monitor_used_flash_info` | `monitor_sui.py` | synthetic `CycleEvent` with `used_flash = true` | surfaces flash-path INFO alert |

## Still Deferred

- incomplete cycle-event evidence replay against `warning_incomplete_cycle_events`
- live object/package mismatch experiments for Cetus paths
- deeper synthetic failures for `deploy_sui.py`
- broader protocol-specific chaos around probe scripts beyond current high-value blockers

