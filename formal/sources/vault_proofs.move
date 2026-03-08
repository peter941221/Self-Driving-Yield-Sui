module formal::vault_proofs;

#[spec_only]
use prover::prover::{requires, ensures};

use self_driving_yield::vault;
use self_driving_yield::types;
use self_driving_yield::queue;
use self_driving_yield::oracle;

#[spec(prove)]
fun calc_shares_first_deposit_is_one_to_one_spec(assets_in: u64): u64 {
    requires(assets_in > 0);
    let result = vault::calc_shares_to_mint(assets_in, 0, 0);
    ensures(result == assets_in);
    result
}

#[spec(prove)]
fun calc_shares_matches_mul_div_when_pool_exists_spec(assets_in: u64, total_assets: u64, total_shares: u64): u64 {
    requires(assets_in > 0);
    requires(total_assets > 0);
    requires(total_shares > 0);
    requires(assets_in.to_int().mul(total_shares.to_int()).div(total_assets.to_int()).lte(18446744073709551615u64.to_int()));
    let result = vault::calc_shares_to_mint(assets_in, total_assets, total_shares);
    ensures(result.to_int() == assets_in.to_int().mul(total_shares.to_int()).div(total_assets.to_int()));
    result
}

#[spec(prove)]
fun set_risk_mode_only_unwind_resets_safe_cycles_spec(): types::RiskMode {
    let mut state = vault::new_state();
    vault::set_risk_mode(&mut state, vault::risk_only_unwind());
    let result = vault::risk_mode(&state);
    ensures(vault::is_only_unwind(&result));
    ensures(vault::safe_cycles_since_storm(&state) == 0);
    result
}

#[spec(prove)]
fun set_risk_mode_normal_restores_safe_cycles_spec(): u64 {
    let mut state = vault::new_state();
    vault::set_risk_mode(&mut state, vault::risk_only_unwind());
    vault::set_risk_mode(&mut state, vault::risk_normal());
    let result = vault::safe_cycles_since_storm(&state);
    ensures(!vault::is_only_unwind(&vault::risk_mode(&state)));
    ensures(result == vault::safe_cycles_to_restore());
    result
}

#[spec(prove)]
fun first_deposit_updates_totals_spec(assets_in: u64): u64 {
    requires(assets_in > 0);
    let mut state = vault::new_state();
    let result = vault::deposit(&mut state, assets_in);
    ensures(result == assets_in);
    ensures(vault::total_assets(&state) == assets_in);
    ensures(vault::treasury_usdc(&state) == assets_in);
    ensures(vault::total_shares(&state) == assets_in);
    result
}

#[spec(prove)]
fun apply_cycle_regime_storm_forces_only_unwind_spec(): types::RiskMode {
    let mut state = vault::new_state();
    vault::apply_cycle_regime(&mut state, &vault::regime_storm());
    let result = vault::risk_mode(&state);
    ensures(vault::is_only_unwind(&result));
    ensures(vault::safe_cycles_since_storm(&state) == 0);
    result
}

#[spec(prove)]
fun apply_cycle_regime_normal_first_safe_cycle_does_not_restore_spec(): u64 {
    let mut state = vault::new_state();
    vault::set_risk_mode(&mut state, vault::risk_only_unwind());
    vault::apply_cycle_regime(&mut state, &vault::regime_normal());
    let result = vault::safe_cycles_since_storm(&state);
    ensures(vault::is_only_unwind(&vault::risk_mode(&state)));
    ensures(result == 1);
    result
}

#[spec(prove)]
fun apply_cycle_regime_normal_second_safe_cycle_restores_spec(): u64 {
    let mut state = vault::new_state();
    vault::set_risk_mode(&mut state, vault::risk_only_unwind());
    vault::apply_cycle_regime(&mut state, &vault::regime_normal());
    vault::apply_cycle_regime(&mut state, &vault::regime_normal());
    let result = vault::safe_cycles_since_storm(&state);
    ensures(!vault::is_only_unwind(&vault::risk_mode(&state)));
    ensures(result == vault::safe_cycles_to_restore());
    result
}

#[spec(prove)]
fun compute_cycle_bounty_is_bounded_spec(remaining: u64, total_assets: u64): u64 {
    let result = vault::compute_cycle_bounty(remaining, total_assets);
    ensures(result <= remaining);
    ensures(result.to_int().lte(total_assets.to_int().mul(vault::max_bounty_bps().to_int()).div(10000u64.to_int())));
    result
}

#[spec(prove)]
fun cycle_empty_state_first_pass_spec(spot_price: u64, ts_ms: u64): (u64, u64) {
    requires(spot_price > 0);
    let mut state = vault::new_state();
    let mut q = queue::new_state();
    let mut o = oracle::new();
    let (moved, bounty) = vault::cycle(&mut state, &mut q, &mut o, spot_price, ts_ms, 0, 0);
    ensures(moved == 0);
    ensures(bounty == 0);
    ensures(vault::total_assets(&state) == 0);
    ensures(vault::treasury_usdc(&state) == 0);
    ensures(vault::last_cycle_ts_ms(&state) == ts_ms);
    ensures(queue::len(&q) == 0);
    ensures(queue::total_pending_shares(&q) == 0);
    ensures(queue::total_pending_usdc(&q) == 0);
    ensures(queue::total_ready_usdc(&q) == 0);
    ensures(oracle::snapshot_count(&o) == 1);
    ensures(oracle::last_snapshot_ts_ms(&o) == ts_ms);
    (moved, bounty)
}
