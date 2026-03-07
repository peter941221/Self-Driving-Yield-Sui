module self_driving_yield::types;

use self_driving_yield::math;

const QUEUE_PRESSURE_LOW_BPS: u64 = 1000;
const QUEUE_PRESSURE_MEDIUM_BPS: u64 = 2500;
const QUEUE_PRESSURE_HIGH_BPS: u64 = 5000;
const BUFFER_EXTRA_LOW_BPS: u64 = 100;
const BUFFER_EXTRA_MEDIUM_BPS: u64 = 250;
const BUFFER_EXTRA_HIGH_BPS: u64 = 500;
const MAX_ADJUSTED_BUFFER_BPS: u64 = 1200;

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

/// Allocation in basis points: (yield, lp, buffer).
public fun get_allocation(regime: &Regime): (u64, u64, u64) {
    match (regime) {
        Regime::Calm => (4000, 5700, 300),
        Regime::Normal => (6000, 3700, 300),
        Regime::Storm => (8000, 1700, 300),
    }
}
