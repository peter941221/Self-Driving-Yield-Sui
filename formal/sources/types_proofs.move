module formal::types_proofs;

#[spec_only]
use prover::prover::{requires, ensures};

use self_driving_yield::types;

#[spec(prove)]
fun allocation_sums_to_10k_spec(regime: types::Regime): (u64, u64, u64) {
    let (yield_bps, lp_bps, buffer_bps) = types::get_allocation(&regime);
    ensures(yield_bps + lp_bps + buffer_bps == 10000);
    (yield_bps, lp_bps, buffer_bps)
}

#[spec(prove)]
fun adjusted_buffer_identity_without_pressure_spec(base_buffer_bps: u64, total_assets: u64, queued_need: u64): u64 {
    requires(base_buffer_bps <= types::max_adjusted_buffer_bps());
    requires(total_assets == 0 || queued_need == 0);
    let result = types::adjusted_buffer_bps(base_buffer_bps, total_assets, queued_need);
    ensures(result == base_buffer_bps);
    result
}

#[spec(prove)]
fun queue_pressure_zero_when_assets_zero_spec(ready_usdc: u64, pending_usdc: u64): u64 {
    let result = types::queue_pressure_score_bps(0, ready_usdc, pending_usdc);
    ensures(result == 0);
    result
}

#[spec(prove)]
fun reserve_target_zero_when_assets_zero_spec(base_buffer_bps: u64, ready_usdc: u64, pending_usdc: u64): u64 {
    let result = types::reserve_target_usdc(base_buffer_bps, 0, ready_usdc, pending_usdc);
    ensures(result == 0);
    result
}

#[spec(prove)]
fun max_deployable_never_exceeds_total_assets_spec(total_assets: u64, reserve_target: u64): u64 {
    let result = types::max_deployable_usdc(total_assets, reserve_target);
    ensures(result <= total_assets);
    result
}

#[spec(prove)]
fun target_hedge_zero_when_unavailable_spec(lp_target: u64, hedge_margin_bps: u64): u64 {
    let result = types::target_hedge_margin_usdc(false, lp_target, hedge_margin_bps);
    ensures(result == 0);
    result
}

#[spec(prove)]
fun target_yield_zero_when_unavailable_spec(total_assets: u64, yield_bps: u64, max_deployable: u64, lp_target: u64, hedge_target: u64): u64 {
    let result = types::target_yield_usdc(false, total_assets, yield_bps, max_deployable, lp_target, hedge_target);
    ensures(result == 0);
    result
}

#[spec(prove)]
fun strategy_leg_action_zero_target_closes_present_position_spec(current_value: u64): u64 {
    let result = types::strategy_leg_action(current_value, 0, true);
    ensures(result == types::strategy_action_close());
    result
}

#[spec(prove)]
fun strategy_leg_action_equal_target_holds_spec(target_value: u64, position_present: bool): u64 {
    let result = types::strategy_leg_action(target_value, target_value, position_present);
    ensures(if (target_value == 0 && position_present) result == types::strategy_action_close() else result == types::strategy_action_hold());
    result
}

#[spec(prove)]
fun strategy_leg_action_target_above_current_deploys_spec(current_value: u64, target_value: u64, position_present: bool): u64 {
    requires(target_value > current_value);
    let result = types::strategy_leg_action(current_value, target_value, position_present);
    ensures(result == types::strategy_action_deploy());
    result
}

#[spec(prove)]
fun strategy_leg_action_target_below_current_reduces_spec(current_value: u64, target_value: u64, position_present: bool): u64 {
    requires(current_value > target_value);
    requires(target_value > 0);
    let result = types::strategy_leg_action(current_value, target_value, position_present);
    ensures(result == types::strategy_action_reduce());
    result
}

#[spec(prove)]
fun should_close_live_position_only_unwind_spec(treasury_usdc: u64, ready_usdc: u64, pending_usdc: u64): bool {
    let result = types::should_close_live_position(true, true, treasury_usdc, ready_usdc, pending_usdc);
    ensures(result);
    result
}

#[spec(prove)]
fun should_close_live_position_without_position_is_false_spec(only_unwind: bool, treasury_usdc: u64, ready_usdc: u64, pending_usdc: u64): bool {
    let result = types::should_close_live_position(false, only_unwind, treasury_usdc, ready_usdc, pending_usdc);
    ensures(!result);
    result
}

#[spec(prove)]
fun queue_pressure_zero_without_demand_spec(total_assets: u64): u64 {
    requires(total_assets > 0);
    let result = types::queue_pressure_score_bps(total_assets, 0, 0);
    ensures(result == 0);
    result
}

#[spec(prove)]
fun reserve_target_small_assets_no_pressure_equals_total_assets_spec(total_assets: u64): u64 {
    requires(total_assets > 0);
    requires(total_assets <= types::emergency_buffer_floor_usdc());
    let result = types::reserve_target_usdc(0, total_assets, 0, 0);
    ensures(result == total_assets);
    result
}

#[spec(prove)]
fun reserve_target_large_assets_zero_buffer_hits_floor_spec(total_assets: u64): u64 {
    requires(total_assets >= types::emergency_buffer_floor_usdc());
    let result = types::reserve_target_usdc(0, total_assets, 0, 0);
    ensures(result == types::emergency_buffer_floor_usdc());
    result
}

#[spec(prove)]
fun queue_pressure_monotone_in_ready_zero_pending_spec(total_assets: u64, ready_lo: u64, ready_hi: u64): u64 {
    requires(total_assets > 0);
    requires(ready_hi >= ready_lo);
    requires(ready_lo.to_int().mul(10000u64.to_int()).div(total_assets.to_int()).lte(18446744073709551615u64.to_int()));
    requires(ready_hi.to_int().mul(10000u64.to_int()).div(total_assets.to_int()).lte(18446744073709551615u64.to_int()));
    let low = types::queue_pressure_score_bps(total_assets, ready_lo, 0);
    let high = types::queue_pressure_score_bps(total_assets, ready_hi, 0);
    ensures(low.to_int() == ready_lo.to_int().mul(10000u64.to_int()).div(total_assets.to_int()));
    ensures(high.to_int() == ready_hi.to_int().mul(10000u64.to_int()).div(total_assets.to_int()));
    ensures(high >= low);
    high
}

#[spec(prove)]
fun adjusted_buffer_never_exceeds_max_spec(base_buffer_bps: u64, total_assets: u64, queued_need: u64): u64 {
    requires(base_buffer_bps <= types::max_adjusted_buffer_bps());
    requires(total_assets == 0 || queued_need == 0 || queued_need.to_int().mul(10000u64.to_int()).div(total_assets.to_int()).lte(18446744073709551615u64.to_int()));
    let result = types::adjusted_buffer_bps(base_buffer_bps, total_assets, queued_need);
    ensures(result <= types::max_adjusted_buffer_bps());
    ensures(result >= base_buffer_bps);
    result
}

#[spec(prove)]
fun adjusted_buffer_high_pressure_caps_spec(): u64 {
    let result = types::adjusted_buffer_bps(800, 10000, 5000);
    ensures(result == types::max_adjusted_buffer_bps());
    result
}
