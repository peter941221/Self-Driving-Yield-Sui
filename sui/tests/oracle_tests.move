module self_driving_yield::oracle_tests;

use self_driving_yield::errors;
use self_driving_yield::oracle;
use self_driving_yield::vault;

fun feed_constant_return_series(s: &mut oracle::OracleState, start_price: u64, return_bps: u64, count: u64) {
    let mut ts: u64 = 0;
    let mut price = start_price;
    let mut i: u64 = 0;
    while (i < count) {
        ts = ts + 1000;
        let _ = oracle::record_snapshot_with_ts(s, price, ts, 0);
        price = ((price as u128) * ((10000 + return_bps) as u128) / 10000) as u64;
        i = i + 1;
    };
}

#[test]
fun cold_start_forces_normal_until_min_samples() {
    let mut s = oracle::new();
    let p = oracle::price_precision();
    let mut ts: u64 = 0;

    // 11 samples -> still cold start => Normal
    let mut i: u64 = 0;
    while (i < 11) {
        ts = ts + 1000;
        let _ = oracle::record_snapshot_with_ts(&mut s, p, ts, 0);
        i = i + 1;
    };
    let r1 = oracle::current_regime(&s);
    assert!(vault::is_regime_normal(&r1), 0);

    // 12th sample -> Calm (vol=0 < 100bps)
    ts = ts + 1000;
    let _ = oracle::record_snapshot_with_ts(&mut s, p, ts, 0);
    let r2 = oracle::current_regime(&s);
    assert!(vault::is_regime_calm(&r2), 0);
}

#[test]
fun regime_boundary_99bps_is_calm() {
    let mut s = oracle::new();
    let p = oracle::price_precision();

    feed_constant_return_series(&mut s, p, 99, 12);

    assert!(oracle::current_volatility_bps(&s) == 99, 0);
    let r = oracle::current_regime(&s);
    assert!(vault::is_regime_calm(&r), 0);
}

#[test]
fun regime_boundary_100bps_is_normal() {
    let mut s = oracle::new();
    let p = oracle::price_precision();

    feed_constant_return_series(&mut s, p, 100, 12);

    assert!(oracle::current_volatility_bps(&s) == 100, 0);
    let r = oracle::current_regime(&s);
    assert!(vault::is_regime_normal(&r), 0);
}

#[test]
fun regime_boundary_101bps_is_normal() {
    let mut s = oracle::new();
    let p = oracle::price_precision();

    feed_constant_return_series(&mut s, p, 101, 12);

    assert!(oracle::current_volatility_bps(&s) == 101, 0);
    let r = oracle::current_regime(&s);
    assert!(vault::is_regime_normal(&r), 0);
}

#[test]
fun regime_boundary_299bps_is_normal() {
    let mut s = oracle::new();
    let p = oracle::price_precision();

    feed_constant_return_series(&mut s, p, 299, 12);

    assert!(oracle::current_volatility_bps(&s) == 299, 0);
    let r = oracle::current_regime(&s);
    assert!(vault::is_regime_normal(&r), 0);
}

#[test]
fun regime_boundary_301bps_is_storm() {
    let mut s = oracle::new();
    let p = oracle::price_precision();

    feed_constant_return_series(&mut s, p, 301, 12);

    assert!(oracle::current_volatility_bps(&s) == 301, 0);
    let r = oracle::current_regime(&s);
    assert!(vault::is_regime_storm(&r), 0);
}

#[test]
fun regime_boundary_300bps_is_storm() {
    let mut s = oracle::new();
    let p = oracle::price_precision();

    feed_constant_return_series(&mut s, p, 300, 12);

    assert!(oracle::current_volatility_bps(&s) == 300, 0);
    let r = oracle::current_regime(&s);
    assert!(vault::is_regime_storm(&r), 0);
}

#[test]
fun min_interval_skips_early_snapshot() {
    let mut s = oracle::new();
    let p = oracle::price_precision();

    let ok1 = oracle::record_snapshot_with_ts(&mut s, p, 1000, 1000);
    let ok2 = oracle::record_snapshot_with_ts(&mut s, p, 1500, 1000);
    let ok3 = oracle::record_snapshot_with_ts(&mut s, p, 2000, 1000);

    assert!(ok1, 0);
    assert!(!ok2, 0);
    assert!(ok3, 0);
    assert!(oracle::snapshot_count(&s) == 2, 0);
}

#[test]
fun ring_buffer_caps_at_max_and_twap_uses_last_48() {
    let mut s = oracle::new();
    let p = oracle::price_precision();
    let mut ts: u64 = 0;

    // Fill 48 snapshots at price p.
    let mut i: u64 = 0;
    while (i < 48) {
        ts = ts + 1000;
        let _ = oracle::record_snapshot_with_ts(&mut s, p, ts, 0);
        i = i + 1;
    };

    // Add 2 more at 2p => ring buffer drops 2 oldest p snapshots.
    let p2 = p * 2;
    ts = ts + 1000;
    let _ = oracle::record_snapshot_with_ts(&mut s, p2, ts, 0);
    ts = ts + 1000;
    let _ = oracle::record_snapshot_with_ts(&mut s, p2, ts, 0);

    assert!(oracle::snapshot_count(&s) == 48, 0);
    // (46*p + 2*2p)/48 = 50p/48 = 1.041666666p (floor)
    assert!(oracle::current_twap(&s) == 1_041_666_666, 0);
}


#[test]
fun oracle_helper_accessors_are_consistent() {
    let s = oracle::new();

    assert!(oracle::price_precision() == 1_000_000_000, 0);
    assert!(oracle::min_samples() == 12, 0);
    assert!(oracle::max_snapshots() == 48, 0);
    assert!(oracle::snapshot_count(&s) == 0, 0);
    assert!(oracle::last_snapshot_ts_ms(&s) == 0, 0);
    assert!(oracle::current_twap(&s) == 0, 0);
    assert!(oracle::current_volatility_bps(&s) == 0, 0);
    assert!(vault::is_regime_normal(&oracle::current_regime(&s)), 0);
}

#[test]
fun compute_regime_helper_covers_all_paths() {
    let cold = oracle::compute_regime(0, 999);
    let calm = oracle::compute_regime(oracle::min_samples(), 99);
    let normal = oracle::compute_regime(oracle::min_samples(), 100);
    let storm = oracle::compute_regime(oracle::min_samples(), 300);

    assert!(vault::is_regime_normal(&cold), 0);
    assert!(vault::is_regime_calm(&calm), 0);
    assert!(vault::is_regime_normal(&normal), 0);
    assert!(vault::is_regime_storm(&storm), 0);
}

#[test]
#[expected_failure(abort_code = errors::E_ZERO_AMOUNT, location = self_driving_yield::oracle)]
fun zero_price_snapshot_aborts() {
    let mut s = oracle::new();
    let _ = oracle::record_snapshot_with_ts(&mut s, 0, 1000, 0);
}


