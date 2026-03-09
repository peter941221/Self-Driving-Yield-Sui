module self_driving_yield::types;

use self_driving_yield::math;

const QUEUE_PRESSURE_LOW_BPS: u64 = 1000;
const QUEUE_PRESSURE_MEDIUM_BPS: u64 = 2500;
const QUEUE_PRESSURE_HIGH_BPS: u64 = 5000;
const BUFFER_EXTRA_LOW_BPS: u64 = 100;
const BUFFER_EXTRA_MEDIUM_BPS: u64 = 250;
const BUFFER_EXTRA_HIGH_BPS: u64 = 500;
const MAX_ADJUSTED_BUFFER_BPS: u64 = 1200;
const PENDING_RESERVE_HAIRCUT_BPS: u64 = 5000;
const EMERGENCY_BUFFER_FLOOR_USDC: u64 = 300;
const STRATEGY_ACTION_HOLD: u64 = 0;
const STRATEGY_ACTION_DEPLOY: u64 = 1;
const STRATEGY_ACTION_REDUCE: u64 = 2;
const STRATEGY_ACTION_CLOSE: u64 = 3;
const LP_ACTION_HOLD: u64 = 0;
const LP_ACTION_OPEN: u64 = 1;
const LP_ACTION_ADD: u64 = 2;
const LP_ACTION_REMOVE: u64 = 3;
const LP_ACTION_CLOSE: u64 = 4;
const STRATEGY_REASON_HOLD: u64 = 0;
const STRATEGY_REASON_TARGET_EXPAND: u64 = 1;
const STRATEGY_REASON_TARGET_SHRINK: u64 = 2;
const STRATEGY_REASON_TARGET_CLOSE: u64 = 3;
const STRATEGY_REASON_ONLY_UNWIND: u64 = 4;
const STRATEGY_REASON_QUEUE_PRESSURE: u64 = 5;

public enum Regime has copy, drop, store {
    Calm,
    Normal,
    Storm,
}

public fun regime_calm(): Regime { Regime::Calm }
public fun regime_normal(): Regime { Regime::Normal }
public fun regime_storm(): Regime { Regime::Storm }

public fun is_regime_calm(r: &Regime): bool {
    match (r) {
        Regime::Calm => true,
        _ => false,
    }
}

public fun is_regime_normal(r: &Regime): bool {
    match (r) {
        Regime::Normal => true,
        _ => false,
    }
}

public fun is_regime_storm(r: &Regime): bool {
    match (r) {
        Regime::Storm => true,
        _ => false,
    }
}

public enum RiskMode has copy, drop, store {
    Normal,
    OnlyUnwind,
}

public fun risk_normal(): RiskMode { RiskMode::Normal }
public fun risk_only_unwind(): RiskMode { RiskMode::OnlyUnwind }

public fun is_only_unwind(m: &RiskMode): bool {
    match (m) {
        RiskMode::OnlyUnwind => true,
        _ => false,
    }
}

public fun max_adjusted_buffer_bps(): u64 { MAX_ADJUSTED_BUFFER_BPS }
public fun pending_reserve_haircut_bps(): u64 { PENDING_RESERVE_HAIRCUT_BPS }
public fun emergency_buffer_floor_usdc(): u64 { EMERGENCY_BUFFER_FLOOR_USDC }
public fun strategy_action_hold(): u64 { STRATEGY_ACTION_HOLD }
public fun strategy_action_deploy(): u64 { STRATEGY_ACTION_DEPLOY }
public fun strategy_action_reduce(): u64 { STRATEGY_ACTION_REDUCE }
public fun strategy_action_close(): u64 { STRATEGY_ACTION_CLOSE }
public fun lp_action_hold(): u64 { LP_ACTION_HOLD }
public fun lp_action_open(): u64 { LP_ACTION_OPEN }
public fun lp_action_add(): u64 { LP_ACTION_ADD }
public fun lp_action_remove(): u64 { LP_ACTION_REMOVE }
public fun lp_action_close(): u64 { LP_ACTION_CLOSE }
public fun strategy_reason_hold(): u64 { STRATEGY_REASON_HOLD }
public fun strategy_reason_target_expand(): u64 { STRATEGY_REASON_TARGET_EXPAND }
public fun strategy_reason_target_shrink(): u64 { STRATEGY_REASON_TARGET_SHRINK }
public fun strategy_reason_target_close(): u64 { STRATEGY_REASON_TARGET_CLOSE }
public fun strategy_reason_only_unwind(): u64 { STRATEGY_REASON_ONLY_UNWIND }
public fun strategy_reason_queue_pressure(): u64 { STRATEGY_REASON_QUEUE_PRESSURE }

public fun adjusted_buffer_bps(base_buffer_bps: u64, total_assets: u64, queued_need: u64): u64 {
    if (total_assets == 0 || queued_need == 0) {
        return base_buffer_bps
    };

    let queue_pressure_bps = math::mul_div(queued_need, 10000, total_assets);
    let extra = if (queue_pressure_bps >= QUEUE_PRESSURE_HIGH_BPS) {
        BUFFER_EXTRA_HIGH_BPS
    } else if (queue_pressure_bps >= QUEUE_PRESSURE_MEDIUM_BPS) {
        BUFFER_EXTRA_MEDIUM_BPS
    } else if (queue_pressure_bps >= QUEUE_PRESSURE_LOW_BPS) {
        BUFFER_EXTRA_LOW_BPS
    } else {
        0
    };
    let adjusted = base_buffer_bps + extra;
    if (adjusted > MAX_ADJUSTED_BUFFER_BPS) {
        MAX_ADJUSTED_BUFFER_BPS
    } else {
        adjusted
    }
}

public fun queue_pressure_score_bps(total_assets: u64, ready_usdc: u64, pending_usdc: u64): u64 {
    if (total_assets == 0) {
        0
    } else {
        let weighted_pending = math::mul_div(pending_usdc, PENDING_RESERVE_HAIRCUT_BPS, 10000);
        let queue_component = math::safe_add(ready_usdc, weighted_pending);
        math::mul_div(queue_component, 10000, total_assets)
    }
}

public fun reserve_target_usdc(
    base_buffer_bps: u64,
    total_assets: u64,
    ready_usdc: u64,
    pending_usdc: u64,
): u64 {
    if (total_assets == 0) {
        return 0
    };

    let weighted_pending = math::mul_div(pending_usdc, PENDING_RESERVE_HAIRCUT_BPS, 10000);
    let queue_component = math::safe_add(ready_usdc, weighted_pending);
    let adjusted_buffer = adjusted_buffer_bps(base_buffer_bps, total_assets, math::safe_add(ready_usdc, pending_usdc));
    let buffer_component = math::mul_div(total_assets, adjusted_buffer, 10000);
    let floor_component = if (total_assets < EMERGENCY_BUFFER_FLOOR_USDC) { total_assets } else { EMERGENCY_BUFFER_FLOOR_USDC };
    let max_ab = if (queue_component > buffer_component) { queue_component } else { buffer_component };
    if (max_ab > floor_component) { max_ab } else { floor_component }
}

public fun max_deployable_usdc(total_assets: u64, reserve_target: u64): u64 {
    if (total_assets > reserve_target) { total_assets - reserve_target } else { 0 }
}

public fun lp_capacity_usdc(max_deployable: u64, hedge_enabled: bool, hedge_margin_bps: u64): u64 {
    if (hedge_enabled && max_deployable > 0) {
        math::mul_div(max_deployable, 10000, 10000 + hedge_margin_bps)
    } else {
        max_deployable
    }
}

public fun target_lp_usdc(
    lp_enabled: bool,
    total_assets: u64,
    lp_bps: u64,
    max_deployable: u64,
    hedge_enabled: bool,
    hedge_margin_bps: u64,
): u64 {
    if (!lp_enabled || total_assets == 0) {
        return 0
    };

    let lp_nominal = math::mul_div(total_assets, lp_bps, 10000);
    let lp_capacity = lp_capacity_usdc(max_deployable, hedge_enabled, hedge_margin_bps);
    if (lp_nominal < lp_capacity) { lp_nominal } else { lp_capacity }
}

public fun target_hedge_margin_usdc(hedge_enabled: bool, lp_target: u64, hedge_margin_bps: u64): u64 {
    if (hedge_enabled && lp_target > 0) {
        math::mul_div(lp_target, hedge_margin_bps, 10000)
    } else {
        0
    }
}

public fun target_yield_usdc(
    yield_enabled: bool,
    total_assets: u64,
    yield_bps: u64,
    max_deployable: u64,
    lp_target: u64,
    hedge_target: u64,
): u64 {
    if (!yield_enabled || total_assets == 0) {
        return 0
    };

    let yield_nominal = math::mul_div(total_assets, yield_bps, 10000);
    let deployable_after_hedge = if (max_deployable > hedge_target) { max_deployable - hedge_target } else { 0 };
    let remaining_after_lp = if (deployable_after_hedge > lp_target) { deployable_after_hedge - lp_target } else { 0 };
    if (yield_nominal < remaining_after_lp) { yield_nominal } else { remaining_after_lp }
}

public fun strategy_leg_action(current_value: u64, target_value: u64, position_present: bool): u64 {
    if (target_value == 0) {
        if (current_value > 0 || position_present) {
            STRATEGY_ACTION_CLOSE
        } else {
            STRATEGY_ACTION_HOLD
        }
    } else if (current_value < target_value) {
        STRATEGY_ACTION_DEPLOY
    } else if (current_value > target_value) {
        STRATEGY_ACTION_REDUCE
    } else {
        STRATEGY_ACTION_HOLD
    }
}

public fun lp_strategy_action(current_value: u64, target_value: u64, position_present: bool): u64 {
    if (target_value == 0) {
        if (current_value > 0 || position_present) {
            LP_ACTION_CLOSE
        } else {
            LP_ACTION_HOLD
        }
    } else if (!position_present) {
        // Live LP state machine: when a non-zero LP budget is desired but no live position exists,
        // the next live action is OPEN, unless we are over-target and should first shrink the LP budget.
        if (current_value > target_value) { LP_ACTION_REMOVE } else { LP_ACTION_OPEN }
    } else if (current_value < target_value) {
        LP_ACTION_ADD
    } else if (current_value > target_value) {
        LP_ACTION_REMOVE
    } else {
        LP_ACTION_HOLD
    }
}

public fun strategy_leg_reason(action: u64): u64 {
    if (action == STRATEGY_ACTION_DEPLOY) {
        STRATEGY_REASON_TARGET_EXPAND
    } else if (action == STRATEGY_ACTION_REDUCE) {
        STRATEGY_REASON_TARGET_SHRINK
    } else if (action == STRATEGY_ACTION_CLOSE) {
        STRATEGY_REASON_TARGET_CLOSE
    } else {
        STRATEGY_REASON_HOLD
    }
}

public fun lp_strategy_reason(
    position_present: bool,
    only_unwind: bool,
    treasury_usdc: u64,
    ready_usdc: u64,
    pending_usdc: u64,
    current_value: u64,
    target_value: u64,
): u64 {
    if (position_present) {
        if (only_unwind) {
            return STRATEGY_REASON_ONLY_UNWIND
        };
        if (math::safe_add(ready_usdc, pending_usdc) > treasury_usdc) {
            return STRATEGY_REASON_QUEUE_PRESSURE
        }
    };

    let action = lp_strategy_action(current_value, target_value, position_present);
    if (action == LP_ACTION_OPEN || action == LP_ACTION_ADD) {
        STRATEGY_REASON_TARGET_EXPAND
    } else if (action == LP_ACTION_REMOVE) {
        STRATEGY_REASON_TARGET_SHRINK
    } else if (action == LP_ACTION_CLOSE) {
        STRATEGY_REASON_TARGET_CLOSE
    } else {
        STRATEGY_REASON_HOLD
    }
}

public fun should_close_live_position(
    position_present: bool,
    only_unwind: bool,
    treasury_usdc: u64,
    ready_usdc: u64,
    pending_usdc: u64,
): bool {
    if (!position_present) {
        return false
    };

    if (only_unwind) {
        return true
    };

    math::safe_add(ready_usdc, pending_usdc) > treasury_usdc
}

/// Allocation in basis points: (yield, lp, buffer).
public fun get_allocation(regime: &Regime): (u64, u64, u64) {
    match (regime) {
        Regime::Calm => (4000, 5700, 300),
        Regime::Normal => (6000, 3700, 300),
        Regime::Storm => (8000, 1700, 300),
    }
}
