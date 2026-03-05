module self_driving_yield::oracle;

use self_driving_yield::errors;
use self_driving_yield::types;

const MIN_SAMPLES: u64 = 12;
const MAX_SNAPSHOTS: u64 = 48;
const PRICE_PRECISION: u64 = 1000000000;

const CALM_VOL_BPS: u64 = 100;
const STORM_VOL_BPS: u64 = 300;

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
    current_volatility_bps: u64,
    current_regime: types::Regime,
}

public fun price_precision(): u64 { PRICE_PRECISION }
public fun min_samples(): u64 { MIN_SAMPLES }
public fun max_snapshots(): u64 { MAX_SNAPSHOTS }

public fun new(): OracleState {
    OracleState {
        snapshots: vector::empty(),
        snapshot_count: 0,
        last_snapshot_ts_ms: 0,
        current_twap: 0,
        current_volatility_bps: 0,
        current_regime: types::regime_normal(),
    }
}

public fun snapshot_count(s: &OracleState): u64 { s.snapshot_count }
public fun last_snapshot_ts_ms(s: &OracleState): u64 { s.last_snapshot_ts_ms }
public fun current_twap(s: &OracleState): u64 { s.current_twap }
public fun current_volatility_bps(s: &OracleState): u64 { s.current_volatility_bps }
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

/// Record a new price snapshot if min interval is satisfied.
/// Returns true if a snapshot is appended; false if called too early.
public fun record_snapshot_with_ts(
    s: &mut OracleState,
    price: u64,
    ts_ms: u64,
    min_interval_ms: u64,
): bool {
    assert!(price > 0, errors::e_zero_amount());

    if (s.last_snapshot_ts_ms != 0 && ts_ms < s.last_snapshot_ts_ms + min_interval_ms) {
        return false
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
    recompute(s);
    true
}

fun recompute(s: &mut OracleState) {
    if (s.snapshot_count == 0) {
        s.current_twap = 0;
        s.current_volatility_bps = 0;
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

    if (count < 2 || twap == 0) {
        s.current_volatility_bps = 0;
        s.current_regime = compute_regime(count, 0);
        return
    };

    let mut sum_abs: u128 = 0;
    i = 0;
    while (i < count) {
        let snap_ref = vector::borrow(&s.snapshots, i);
        let p = snap_ref.price;
        let diff = if (p >= twap) { p - twap } else { twap - p };
        sum_abs = sum_abs + (diff as u128);
        i = i + 1;
    };

    let denom: u128 = (twap as u128) * (count as u128);
    let vol_bps_u128 = (sum_abs * 10000) / denom;
    let vol_bps: u64 = vol_bps_u128 as u64;

    s.current_volatility_bps = vol_bps;
    s.current_regime = compute_regime(count, vol_bps);
}
