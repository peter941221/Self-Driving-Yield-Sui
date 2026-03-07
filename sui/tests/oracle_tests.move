module self_driving_yield::oracle_tests;

use self_driving_yield::errors;
use self_driving_yield::oracle;
use self_driving_yield::vault;

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

    // twap will be exactly p, mean abs deviation = 0.99% => 99 bps
    let hi = p + 9_900_000; // +0.99%
    let lo = p - 9_900_000; // -0.99%
    let mut ts: u64 = 0;
    let mut i: u64 = 0;
    while (i < 12) {
        ts = ts + 1000;
        let price = if (i % 2 == 0) { hi } else { lo };
        let _ = oracle::record_snapshot_with_ts(&mut s, price, ts, 0);
        i = i + 1;
    };

    assert!(oracle::current_volatility_bps(&s) == 99, 0);
    let r = oracle::current_regime(&s);
    assert!(vault::is_regime_calm(&r), 0);
}

#[test]
fun regime_boundary_100bps_is_normal() {
    let mut s = oracle::new();
    let p = oracle::price_precision();

    // mean abs deviation = 1.00% => 100 bps
    let hi = p + 10_000_000;
    let lo = p - 10_000_000;
    let mut ts: u64 = 0;
    let mut i: u64 = 0;
    while (i < 12) {
        ts = ts + 1000;
        let price = if (i % 2 == 0) { hi } else { lo };
        let _ = oracle::record_snapshot_with_ts(&mut s, price, ts, 0);
        i = i + 1;
    };

    assert!(oracle::current_volatility_bps(&s) == 100, 0);
    let r = oracle::current_regime(&s);
    assert!(vault::is_regime_normal(&r), 0);
}

#[test]
fun regime_boundary_101bps_is_normal() {
    let mut s = oracle::new();
    let p = oracle::price_precision();

    // mean abs deviation = 1.01% => 101 bps
    let hi = p + 10_100_000;
    let lo = p - 10_100_000;
    let mut ts: u64 = 0;
    let mut i: u64 = 0;
    while (i < 12) {
        ts = ts + 1000;
        let price = if (i % 2 == 0) { hi } else { lo };
        let _ = oracle::record_snapshot_with_ts(&mut s, price, ts, 0);
        i = i + 1;
    };

    assert!(oracle::current_volatility_bps(&s) == 101, 0);
    let r = oracle::current_regime(&s);
    assert!(vault::is_regime_normal(&r), 0);
}

#[test]
fun regime_boundary_299bps_is_normal() {
    let mut s = oracle::new();
    let p = oracle::price_precision();

    // mean abs deviation = 2.99% => 299 bps
    let hi = p + 29_900_000;
    let lo = p - 29_900_000;
    let mut ts: u64 = 0;
    let mut i: u64 = 0;
    while (i < 12) {
        ts = ts + 1000;
        let price = if (i % 2 == 0) { hi } else { lo };
        let _ = oracle::record_snapshot_with_ts(&mut s, price, ts, 0);
        i = i + 1;
    };

    assert!(oracle::current_volatility_bps(&s) == 299, 0);
    let r = oracle::current_regime(&s);
    assert!(vault::is_regime_normal(&r), 0);
}

#[test]
fun regime_boundary_301bps_is_storm() {
    let mut s = oracle::new();
    let p = oracle::price_precision();

    // mean abs deviation = 3.01% => 301 bps
    let hi = p + 30_100_000;
    let lo = p - 30_100_000;
    let mut ts: u64 = 0;
    let mut i: u64 = 0;
    while (i < 12) {
        ts = ts + 1000;
        let price = if (i % 2 == 0) { hi } else { lo };
        let _ = oracle::record_snapshot_with_ts(&mut s, price, ts, 0);
        i = i + 1;
    };

    assert!(oracle::current_volatility_bps(&s) == 301, 0);
    let r = oracle::current_regime(&s);
    assert!(vault::is_regime_storm(&r), 0);
}

#[test]
fun regime_boundary_300bps_is_storm() {
    let mut s = oracle::new();
    let p = oracle::price_precision();

    // mean abs deviation = 3.00% => 300 bps
    let hi = p + 30_000_000;
    let lo = p - 30_000_000;
    let mut ts: u64 = 0;
    let mut i: u64 = 0;
    while (i < 12) {
        ts = ts + 1000;
        let price = if (i % 2 == 0) { hi } else { lo };
        let _ = oracle::record_snapshot_with_ts(&mut s, price, ts, 0);
        i = i + 1;
    };

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


