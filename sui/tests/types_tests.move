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
