module self_driving_yield::types_tests;

use self_driving_yield::types;

#[test]
fun regime_helpers_cover_all_variants() {
    let calm = types::regime_calm();
    let normal = types::regime_normal();
    let storm = types::regime_storm();

    assert!(types::is_regime_calm(&calm), 0);
    assert!(!types::is_regime_calm(&normal), 0);
    assert!(!types::is_regime_calm(&storm), 0);

    assert!(types::is_regime_normal(&normal), 0);
    assert!(!types::is_regime_normal(&calm), 0);
    assert!(!types::is_regime_normal(&storm), 0);

    assert!(types::is_regime_storm(&storm), 0);
    assert!(!types::is_regime_storm(&calm), 0);
    assert!(!types::is_regime_storm(&normal), 0);
}

#[test]
fun risk_mode_helpers_cover_all_variants() {
    let normal = types::risk_normal();
    let only = types::risk_only_unwind();

    assert!(!types::is_only_unwind(&normal), 0);
    assert!(types::is_only_unwind(&only), 0);
}

#[test]
fun allocation_sums_to_10k_bps() {
    let calm = types::regime_calm();
    let (y, lp, buf) = types::get_allocation(&calm);
    assert!(y + lp + buf == 10000, 0);

    let normal = types::regime_normal();
    let (y, lp, buf) = types::get_allocation(&normal);
    assert!(y + lp + buf == 10000, 0);

    let storm = types::regime_storm();
    let (y, lp, buf) = types::get_allocation(&storm);
    assert!(y + lp + buf == 10000, 0);
}

#[test]
fun adjusted_buffer_bps_grows_with_queue_pressure() {
    assert!(types::adjusted_buffer_bps(300, 0, 0) == 300, 0);
    assert!(types::adjusted_buffer_bps(300, 10_000, 999) == 300, 0);
    assert!(types::adjusted_buffer_bps(300, 10_000, 1_000) == 400, 0);
    assert!(types::adjusted_buffer_bps(300, 10_000, 2_500) == 550, 0);
    assert!(types::adjusted_buffer_bps(300, 10_000, 5_000) == 800, 0);
    assert!(types::adjusted_buffer_bps(900, 10_000, 5_000) == types::max_adjusted_buffer_bps(), 0);
}

#[test]
fun reserve_target_uses_queue_ratio_and_floor() {
    assert!(types::queue_pressure_score_bps(0, 0, 0) == 0, 0);
    assert!(types::queue_pressure_score_bps(10_000, 1_000, 2_000) == 2_000, 0);

    assert!(types::reserve_target_usdc(300, 10_000, 0, 0) == 300, 0);
    assert!(types::reserve_target_usdc(300, 10_000, 100, 200) == 300, 0);
    assert!(types::reserve_target_usdc(300, 10_000, 2_000, 2_000) == 3_000, 0);
    assert!(types::reserve_target_usdc(300, 200, 0, 0) == 200, 0);
}
