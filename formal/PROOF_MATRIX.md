# Formal Proof Matrix

This matrix maps the current green `formal/` suite to the repo's core invariants and helper behaviors.

## Scope

- Package: `formal/`
- Runner: `bash scripts/formal_verify_wsl.sh -v`
- Current focus: helper/accounting/risk kernel
- Current exclusions: `vault::cycle()` full state machine, live shared-object flows, cross-network/runtime guarantees

## Matrix

| Proof Entry | Target / Function | Property Class | Current Purpose |
|---|---|---|---|
| `oracle_proofs::compute_regime_cold_start_forces_normal_spec` | `oracle::compute_regime` | cold start | `sample_count < MIN_SAMPLES => NORMAL` |
| `oracle_proofs::compute_regime_calm_range_spec` | `oracle::compute_regime` | regime classification | calm range returns `Calm` |
| `oracle_proofs::compute_regime_normal_range_spec` | `oracle::compute_regime` | regime classification | normal range returns `Normal` |
| `oracle_proofs::compute_regime_storm_range_spec` | `oracle::compute_regime` | regime classification | storm range returns `Storm` |
| `oracle_proofs::first_snapshot_transition_spec` | `oracle::record_snapshot_with_ts` | snapshot transition | first snapshot creates 1-snapshot state and updates timestamp |
| `queue_proofs::new_queue_state_starts_empty_spec` | `queue::new_state` | initialization | empty queue starts with zero totals |
| `queue_proofs::enqueue_single_request_updates_totals_spec` | `queue::enqueue` | queue accounting | enqueue updates ids, pending totals, and request fields |
| `queue_proofs::claim_ready_reduces_reserved_total_spec` | `queue::claim_ready` | reserved-liquidity accounting | claiming ready request decrements reserved ready total |
| `queue_proofs::process_queue_empty_queue_target_spec` | `queue::process_queue` | empty-queue no-op slice | empty queue with zero treasury returns zero moved |
| `types_proofs::allocation_sums_to_10k_spec` | `types::get_allocation` | allocation math | allocation always sums to `10000` bps |
| `types_proofs::adjusted_buffer_identity_without_pressure_spec` | `types::adjusted_buffer_bps` | reserve math | no pressure leaves base buffer unchanged |
| `types_proofs::queue_pressure_zero_when_assets_zero_spec` | `types::queue_pressure_score_bps` | reserve math | zero assets forces zero queue pressure |
| `types_proofs::reserve_target_zero_when_assets_zero_spec` | `types::reserve_target_usdc` | reserve math | zero assets forces zero reserve target |
| `types_proofs::queue_pressure_zero_without_demand_spec` | `types::queue_pressure_score_bps` | reserve math | zero demand yields zero pressure |
| `types_proofs::reserve_target_small_assets_no_pressure_equals_total_assets_spec` | `types::reserve_target_usdc` | reserve floor | small asset base collapses reserve to total assets |
| `types_proofs::reserve_target_large_assets_zero_buffer_hits_floor_spec` | `types::reserve_target_usdc` | reserve floor | zero-buffer large asset case hits emergency floor |
| `types_proofs::queue_pressure_monotone_in_ready_zero_pending_spec` | `types::queue_pressure_score_bps` | monotonicity slice | with zero pending, more ready demand never lowers queue pressure |
| `vault_proofs::calc_shares_first_deposit_is_one_to_one_spec` | `vault::calc_shares_to_mint` | share math | first deposit mints 1:1 |
| `vault_proofs::calc_shares_matches_mul_div_when_pool_exists_spec` | `vault::calc_shares_to_mint` | share math | live-pool mint math matches floor division |
| `vault_proofs::set_risk_mode_only_unwind_resets_safe_cycles_spec` | `vault::set_risk_mode` | risk mode | entering `OnlyUnwind` resets safe-cycle counter |
| `vault_proofs::set_risk_mode_normal_restores_safe_cycles_spec` | `vault::set_risk_mode` | risk mode | returning to normal restores threshold counter |
| `vault_proofs::first_deposit_updates_totals_spec` | `vault::deposit` | deposit accounting | first deposit updates assets / treasury / shares |
| `vault_proofs::apply_cycle_regime_storm_forces_only_unwind_spec` | `vault::apply_cycle_regime` | cycle slice | storm branch forces `OnlyUnwind` |
| `vault_proofs::apply_cycle_regime_normal_first_safe_cycle_does_not_restore_spec` | `vault::apply_cycle_regime` | cycle slice | first safe normal cycle increments counter but keeps `OnlyUnwind` |
| `vault_proofs::apply_cycle_regime_normal_second_safe_cycle_restores_spec` | `vault::apply_cycle_regime` | cycle slice | second safe normal cycle restores `Normal` mode |
| `vault_proofs::compute_cycle_bounty_is_bounded_spec` | `vault::compute_cycle_bounty` | bounty bound | bounty is bounded by remaining and capped share of assets |
| `vault_proofs::cycle_empty_state_first_pass_spec` | `vault::cycle` | cycle wrapper slice | empty-state first pass keeps assets/treasury at zero, snapshots once, and updates cycle timestamp |
| `yield_source_proofs::normalize_receipt_zero_when_invalid_spec` | `yield_source::normalize_live_receipt_id` | live bookkeeping | invalid receipt/value/config normalizes to zero |
| `yield_source_proofs::normalize_receipt_preserves_valid_id_spec` | `yield_source::normalize_live_receipt_id` | live bookkeeping | valid receipt id is preserved |
| `yield_source_proofs::full_withdraw_zeroes_remaining_value_spec` | `yield_source::value_after_live_withdraw` | live bookkeeping | full withdraw zeroes remaining value |
| `yield_source_proofs::partial_withdraw_subtracts_remaining_value_spec` | `yield_source::value_after_live_withdraw` | live bookkeeping | partial withdraw preserves subtraction identity |
| `yield_source_proofs::full_withdraw_zeroes_principal_spec` | `yield_source::principal_after_live_withdraw` | live bookkeeping | terminal withdraw clears principal |
| `yield_source_proofs::accrued_yield_is_non_negative_spec` | `yield_source::accrued_yield_amount` | live bookkeeping | accrued yield is never negative |

## Still Deferred

- `queue::process_queue` stronger FIFO / progress proof
- `oracle::record_snapshot_with_ts` richer post-state proof beyond first-snapshot slice
- reserve target stronger monotonicity / ready-coverage proofs under wider assumptions
- `vault::cycle()` full multi-phase state-machine proof
- live shared-object / adapter / protocol-object proofs
