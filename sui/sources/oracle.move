module self_driving_yield::oracle;

use self_driving_yield::errors;
use self_driving_yield::math;
use self_driving_yield::types;

const MIN_SAMPLES: u64 = 12;
const MAX_SNAPSHOTS: u64 = 48;
const PRICE_PRECISION: u64 = 1000000000;

const CALM_VOL_BPS: u64 = 100;
const CALM_EXIT_VOL_BPS: u64 = 120;
const STORM_VOL_BPS: u64 = 300;
const STORM_EXIT_VOL_BPS: u64 = 250;
const EWMA_LAMBDA_BPS: u64 = 9400;

public struct PriceSnapshot has copy, drop, store {
    ts_ms: u64,
    /// Price scaled by PRICE_PRECISION (e.g., 1.00 = 1_000_000_000).
    price: u64,
}

public struct OracleState has store, drop {
    snapshots: vector<PriceSnapshot>,
    snapshot_count: u64,
    last_snapshot_ts_ms: u64,
    current_twap: u64,
    ewma_variance_bps2: u128,
    current_volatility_bps: u64,
    current_confidence_bps: u64,
    current_effective_volatility_bps: u64,
    current_regime: types::Regime,
}

public fun price_precision(): u64 { PRICE_PRECISION }
public fun min_samples(): u64 { MIN_SAMPLES }
public fun max_snapshots(): u64 { MAX_SNAPSHOTS }
public fun ewma_lambda_bps(): u64 { EWMA_LAMBDA_BPS }
public fun calm_vol_bps(): u64 { CALM_VOL_BPS }
public fun calm_exit_vol_bps(): u64 { CALM_EXIT_VOL_BPS }
public fun storm_vol_bps(): u64 { STORM_VOL_BPS }
public fun storm_exit_vol_bps(): u64 { STORM_EXIT_VOL_BPS }

public fun new(): OracleState {
    OracleState {
        snapshots: vector::empty(),
        snapshot_count: 0,
        last_snapshot_ts_ms: 0,
        current_twap: 0,
        ewma_variance_bps2: 0,
        current_volatility_bps: 0,
        current_confidence_bps: 0,
        current_effective_volatility_bps: 0,
        current_regime: types::regime_normal(),
    }
}

public fun snapshot_count(s: &OracleState): u64 { s.snapshot_count }
public fun snapshots_len(s: &OracleState): u64 { vector::length(&s.snapshots) }
public fun last_snapshot_ts_ms(s: &OracleState): u64 { s.last_snapshot_ts_ms }
public fun current_twap(s: &OracleState): u64 { s.current_twap }
public fun current_volatility_bps(s: &OracleState): u64 { s.current_volatility_bps }
public fun current_confidence_bps(s: &OracleState): u64 { s.current_confidence_bps }
public fun current_effective_volatility_bps(s: &OracleState): u64 { s.current_effective_volatility_bps }
public fun current_regime(s: &OracleState): types::Regime { s.current_regime }

public fun compute_regime(sample_count: u64, volatility_bps: u64): types::Regime {
    if (sample_count < MIN_SAMPLES) {
        types::regime_normal()
    } else if (volatility_bps < CALM_VOL_BPS) {
        types::regime_calm()
    } else if (volatility_bps < STORM_VOL_BPS) {
        types::regime_normal()
    } else {
        types::regime_storm()
    }
}

public fun compute_effective_volatility_bps(volatility_bps: u64, confidence_bps: u64): u64 {
    math::safe_add(volatility_bps, confidence_bps)
}

public fun compute_regime_with_hysteresis(
    previous_regime: &types::Regime,
    sample_count: u64,
    effective_volatility_bps: u64,
): types::Regime {
    if (sample_count < MIN_SAMPLES) {
        return types::regime_normal()
    };

    if (types::is_regime_calm(previous_regime)) {
        if (effective_volatility_bps < CALM_EXIT_VOL_BPS) {
            types::regime_calm()
        } else if (effective_volatility_bps >= STORM_VOL_BPS) {
            types::regime_storm()
        } else {
            types::regime_normal()
        }
    } else if (types::is_regime_storm(previous_regime)) {
        if (effective_volatility_bps >= STORM_EXIT_VOL_BPS) {
            types::regime_storm()
        } else if (effective_volatility_bps < CALM_VOL_BPS) {
            types::regime_calm()
        } else {
            types::regime_normal()
        }
    } else {
        if (effective_volatility_bps < CALM_VOL_BPS) {
            types::regime_calm()
        } else if (effective_volatility_bps >= STORM_VOL_BPS) {
            types::regime_storm()
        } else {
            types::regime_normal()
        }
    }
}

/// Record a new price snapshot if min interval is satisfied.
/// Returns true if a snapshot is appended; false if called too early.
public fun record_snapshot_with_ts(
    s: &mut OracleState,
    price: u64,
    ts_ms: u64,
    min_interval_ms: u64,
): bool {
    record_snapshot_with_confidence_with_ts(s, price, 0, ts_ms, min_interval_ms)
}

public fun record_snapshot_with_confidence_with_ts(
    s: &mut OracleState,
    price: u64,
    confidence_bps: u64,
    ts_ms: u64,
    min_interval_ms: u64,
): bool {
    assert!(price > 0, errors::e_zero_amount());

    if (s.last_snapshot_ts_ms != 0 && ts_ms < s.last_snapshot_ts_ms + min_interval_ms) {
        return false
    };

    if (s.snapshot_count == 0) {
        vector::push_back(&mut s.snapshots, PriceSnapshot { ts_ms, price });
        s.snapshot_count = 1;
        s.last_snapshot_ts_ms = ts_ms;
        s.current_twap = price;
        s.ewma_variance_bps2 = 0;
        s.current_volatility_bps = 0;
        s.current_confidence_bps = confidence_bps;
        s.current_effective_volatility_bps = compute_effective_volatility_bps(0, confidence_bps);
        s.current_regime = compute_regime_with_hysteresis(&s.current_regime, 1, s.current_effective_volatility_bps);
        return true
    };

    let prev_price = vector::borrow(&s.snapshots, s.snapshot_count - 1).price;
    let diff = if (price >= prev_price) { price - prev_price } else { prev_price - price };
    let ret_bps = ((diff as u128) * 10000 + ((prev_price as u128) / 2)) / (prev_price as u128);
    let ret_sq = ret_bps * ret_bps;
    if (s.snapshot_count == 1) {
        s.ewma_variance_bps2 = ret_sq;
    } else {
        s.ewma_variance_bps2 = (
            s.ewma_variance_bps2 * (EWMA_LAMBDA_BPS as u128) + ret_sq * ((10000 - EWMA_LAMBDA_BPS) as u128) + 5000
        ) / 10000;
    };

    if (s.snapshot_count < MAX_SNAPSHOTS) {
        vector::push_back(&mut s.snapshots, PriceSnapshot { ts_ms, price });
        s.snapshot_count = s.snapshot_count + 1;
    } else {
        let _old = vector::remove(&mut s.snapshots, 0);
        vector::push_back(&mut s.snapshots, PriceSnapshot { ts_ms, price });
        s.snapshot_count = MAX_SNAPSHOTS;
    };

    s.last_snapshot_ts_ms = ts_ms;
    s.current_confidence_bps = confidence_bps;
    recompute(s);
    true
}

fun recompute(s: &mut OracleState) {
    if (s.snapshot_count == 0) {
        s.current_twap = 0;
        s.ewma_variance_bps2 = 0;
        s.current_volatility_bps = 0;
        s.current_effective_volatility_bps = compute_effective_volatility_bps(0, s.current_confidence_bps);
        s.current_regime = types::regime_normal();
        return
    };

    let count = s.snapshot_count;

    let mut sum: u128 = 0;
    let mut i = 0;
    while (i < count) {
        let snap_ref = vector::borrow(&s.snapshots, i);
        sum = sum + (snap_ref.price as u128);
        i = i + 1;
    };

    let twap_u128 = sum / (count as u128);
    let twap: u64 = twap_u128 as u64;
    s.current_twap = twap;

    if (count < 2) {
        s.ewma_variance_bps2 = 0;
        s.current_volatility_bps = 0;
        s.current_effective_volatility_bps = compute_effective_volatility_bps(0, s.current_confidence_bps);
        s.current_regime = compute_regime_with_hysteresis(&s.current_regime, count, s.current_effective_volatility_bps);
        return
    };

    let vol_bps = math::sqrt_u128(s.ewma_variance_bps2);

    s.current_volatility_bps = vol_bps;
    s.current_effective_volatility_bps = compute_effective_volatility_bps(vol_bps, s.current_confidence_bps);
    s.current_regime = compute_regime_with_hysteresis(&s.current_regime, count, s.current_effective_volatility_bps);
}

#[test_only]
public fun recompute_for_testing(s: &mut OracleState) {
    recompute(s);
}

#[test_only]
public fun set_confidence_bps_for_testing(s: &mut OracleState, confidence_bps: u64) {
    s.current_confidence_bps = confidence_bps;
    s.current_effective_volatility_bps = compute_effective_volatility_bps(s.current_volatility_bps, confidence_bps);
    s.current_regime = compute_regime_with_hysteresis(&s.current_regime, s.snapshot_count, s.current_effective_volatility_bps);
}
