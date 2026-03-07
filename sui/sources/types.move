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

/// Allocation in basis points: (yield, lp, buffer).
public fun get_allocation(regime: &Regime): (u64, u64, u64) {
    match (regime) {
        Regime::Calm => (4000, 5700, 300),
        Regime::Normal => (6000, 3700, 300),
        Regime::Storm => (8000, 1700, 300),
    }
}
