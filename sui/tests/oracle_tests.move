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
    assert!(oracle::current_confidence_bps(&s) == 0, 0);
    assert!(oracle::current_effective_volatility_bps(&s) == 0, 0);
    assert!(vault::is_regime_normal(&oracle::current_regime(&s)), 0);
}

#[test]
fun confidence_penalty_increases_effective_volatility() {
    let mut s = oracle::new();
    let p = oracle::price_precision();
    feed_constant_return_series(&mut s, p, 99, 12);
    let base_vol = oracle::current_volatility_bps(&s);
    oracle::set_confidence_bps_for_testing(&mut s, 25);
    assert!(base_vol == 99, 0);
    assert!(oracle::current_confidence_bps(&s) == 25, 0);
    assert!(oracle::current_effective_volatility_bps(&s) == 124, 0);
    let r = oracle::current_regime(&s);
    assert!(vault::is_regime_normal(&r), 0);
}

#[test]
fun hysteresis_keeps_calm_until_exit_threshold() {
    let calm_prev = vault::regime_calm();
    let stay_calm = oracle::compute_regime_with_hysteresis(&calm_prev, oracle::min_samples(), 119);
    let leave_calm = oracle::compute_regime_with_hysteresis(&calm_prev, oracle::min_samples(), 120);
    assert!(vault::is_regime_calm(&stay_calm), 0);
    assert!(vault::is_regime_normal(&leave_calm), 0);
}

#[test]
fun hysteresis_keeps_storm_until_exit_threshold() {
    let storm_prev = vault::regime_storm();
    let stay_storm = oracle::compute_regime_with_hysteresis(&storm_prev, oracle::min_samples(), 250);
    let leave_storm = oracle::compute_regime_with_hysteresis(&storm_prev, oracle::min_samples(), 249);
    assert!(vault::is_regime_storm(&stay_storm), 0);
    assert!(vault::is_regime_normal(&leave_storm) || vault::is_regime_calm(&leave_storm), 0);
}

#[test]
fun oracle_parameter_accessors_cover_hysteresis_constants() {
    assert!(oracle::calm_vol_bps() == 100, 0);
    assert!(oracle::calm_exit_vol_bps() == 120, 0);
    assert!(oracle::storm_vol_bps() == 300, 0);
    assert!(oracle::storm_exit_vol_bps() == 250, 0);
    assert!(oracle::compute_effective_volatility_bps(99, 25) == 124, 0);
}

#[test]
fun record_snapshot_with_confidence_tracks_effective_volatility() {
    let mut s = oracle::new();
    let p = oracle::price_precision();
    let mut ts: u64 = 0;
    let mut i: u64 = 0;
    while (i < 12) {
        ts = ts + 1000;
        let ok = oracle::record_snapshot_with_confidence_with_ts(&mut s, p, 20, ts, 0);
        assert!(ok, 0);
        i = i + 1;
    };
    assert!(oracle::current_confidence_bps(&s) == 20, 0);
    assert!(oracle::current_volatility_bps(&s) == 0, 0);
    assert!(oracle::current_effective_volatility_bps(&s) == 20, 0);
    let r = oracle::current_regime(&s);
    assert!(vault::is_regime_calm(&r), 0);
}

#[test]
fun confidence_snapshot_respects_min_interval() {
    let mut s = oracle::new();
    let p = oracle::price_precision();
    let ok1 = oracle::record_snapshot_with_confidence_with_ts(&mut s, p, 10, 1000, 1000);
    let ok2 = oracle::record_snapshot_with_confidence_with_ts(&mut s, p, 20, 1500, 1000);
    let ok3 = oracle::record_snapshot_with_confidence_with_ts(&mut s, p, 30, 2000, 1000);
    assert!(ok1, 0);
    assert!(!ok2, 0);
    assert!(ok3, 0);
    assert!(oracle::snapshot_count(&s) == 2, 0);
    assert!(oracle::current_confidence_bps(&s) == 30, 0);
}

#[test]
fun hysteresis_calm_can_jump_to_storm() {
    let calm_prev = vault::regime_calm();
    let next = oracle::compute_regime_with_hysteresis(&calm_prev, oracle::min_samples(), 350);
    assert!(vault::is_regime_storm(&next), 0);
}

#[test]
fun hysteresis_storm_can_jump_to_calm() {
    let storm_prev = vault::regime_storm();
    let next = oracle::compute_regime_with_hysteresis(&storm_prev, oracle::min_samples(), 50);
    assert!(vault::is_regime_calm(&next), 0);
}

#[test]
fun hysteresis_storm_can_transition_to_normal_in_middle_band() {
    let storm_prev = vault::regime_storm();
    // Between CALM_VOL_BPS and STORM_EXIT_VOL_BPS => Normal.
    let next = oracle::compute_regime_with_hysteresis(&storm_prev, oracle::min_samples(), 150);
    assert!(vault::is_regime_normal(&next), 0);
}

#[test]
fun hysteresis_normal_stays_normal_in_middle_band() {
    let normal_prev = vault::regime_normal();
    let next = oracle::compute_regime_with_hysteresis(&normal_prev, oracle::min_samples(), 150);
    assert!(vault::is_regime_normal(&next), 0);
}

#[test]
fun hysteresis_normal_can_enter_calm_and_storm() {
    let normal_prev = vault::regime_normal();
    let calm_next = oracle::compute_regime_with_hysteresis(&normal_prev, oracle::min_samples(), 50);
    let storm_next = oracle::compute_regime_with_hysteresis(&normal_prev, oracle::min_samples(), 350);
    assert!(vault::is_regime_calm(&calm_next), 0);
    assert!(vault::is_regime_storm(&storm_next), 0);
}

#[test]
fun effective_volatility_helper_is_additive_at_zero() {
    assert!(oracle::compute_effective_volatility_bps(0, 0) == 0, 0);
    assert!(oracle::compute_effective_volatility_bps(0, 77) == 77, 0);
    assert!(oracle::compute_effective_volatility_bps(88, 0) == 88, 0);
}

#[test]
fun hysteresis_cold_start_forces_normal() {
    let prev = vault::regime_storm();
    let next = oracle::compute_regime_with_hysteresis(&prev, 0, 999);
    assert!(vault::is_regime_normal(&next), 0);
}

#[test]
fun confidence_path_updates_snapshot_accessors() {
    let mut s = oracle::new();
    let p = oracle::price_precision();
    let ok = oracle::record_snapshot_with_confidence_with_ts(&mut s, p + 1, 9, 1234, 0);
    assert!(ok, 0);
    assert!(oracle::snapshot_count(&s) == 1, 0);
    assert!(oracle::snapshots_len(&s) == 1, 0);
    assert!(oracle::last_snapshot_ts_ms(&s) == 1234, 0);
    assert!(oracle::current_twap(&s) == p + 1, 0);
    assert!(oracle::current_confidence_bps(&s) == 9, 0);
}

#[test]
fun recompute_for_testing_covers_zero_and_single_snapshot_paths() {
    let mut s = oracle::new();
    oracle::recompute_for_testing(&mut s);
    assert!(oracle::snapshot_count(&s) == 0, 0);
    assert!(oracle::current_twap(&s) == 0, 0);
    assert!(oracle::current_volatility_bps(&s) == 0, 0);

    let p = oracle::price_precision();
    let ok = oracle::record_snapshot_with_ts(&mut s, p, 1000, 0);
    assert!(ok, 0);
    oracle::recompute_for_testing(&mut s);
    assert!(oracle::snapshot_count(&s) == 1, 0);
    assert!(oracle::current_twap(&s) == p, 0);
    assert!(oracle::current_volatility_bps(&s) == 0, 0);
}

#[test]
fun confidence_ring_buffer_caps_and_keeps_latest_confidence() {
    let mut s = oracle::new();
    let p = oracle::price_precision();
    let mut ts: u64 = 0;
    let mut i: u64 = 0;
    while (i < 50) {
        ts = ts + 1000;
        let ok = oracle::record_snapshot_with_confidence_with_ts(&mut s, p + i, (i % 10), ts, 0);
        assert!(ok, 0);
        i = i + 1;
    };
    assert!(oracle::snapshot_count(&s) == oracle::max_snapshots(), 0);
    assert!(oracle::snapshots_len(&s) == oracle::max_snapshots(), 0);
    assert!(oracle::last_snapshot_ts_ms(&s) == 50_000, 0);
    assert!(oracle::current_confidence_bps(&s) == 9, 0);
}

#[test]
fun confidence_series_enters_storm_when_effective_vol_is_high() {
    let mut s = oracle::new();
    let p = oracle::price_precision();
    let mut ts: u64 = 0;
    let mut price = p;
    let mut i: u64 = 0;
    while (i < 12) {
        ts = ts + 1000;
        let _ = oracle::record_snapshot_with_confidence_with_ts(&mut s, price, 50, ts, 0);
        price = ((price as u128) * 10300 / 10000) as u64;
        i = i + 1;
    };
    assert!(oracle::current_volatility_bps(&s) >= oracle::storm_vol_bps(), 0);
    assert!(oracle::current_effective_volatility_bps(&s) >= oracle::storm_vol_bps(), 0);
    assert!(vault::is_regime_storm(&oracle::current_regime(&s)), 0);
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


