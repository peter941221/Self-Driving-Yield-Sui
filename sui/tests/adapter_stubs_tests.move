module self_driving_yield::adapter_stubs_tests;

use self_driving_yield::config;
use self_driving_yield::cetus_amm;
use self_driving_yield::perp_hedge;
use self_driving_yield::rebalancer;
use self_driving_yield::yield_source;

#[test]
fun adapters_are_disabled_until_configured() {
    let mut ctx = tx_context::dummy();
    let (mut cfg, cap) = config::new(0, 0, &mut ctx);

    assert!(!cetus_amm::is_available(&cfg), 0);
    assert!(!yield_source::is_available(&cfg), 0);
    assert!(!perp_hedge::is_available(&cfg), 0);
    assert!(!rebalancer::is_available(&cfg), 0);

    config::set_cetus_pool_id(&mut cfg, &cap, @0x111);
    config::set_lending_market_id(&mut cfg, &cap, @0x222);
    config::set_perps_market_id(&mut cfg, &cap, @0x333);
    config::set_flashloan_provider_id(&mut cfg, &cap, @0x444);

    assert!(cetus_amm::is_available(&cfg), 0);
    assert!(yield_source::is_available(&cfg), 0);
    assert!(perp_hedge::is_available(&cfg), 0);
    assert!(rebalancer::is_available(&cfg), 0);

    // Consume key objects to satisfy no-drop restriction in unit tests.
    transfer::public_transfer(cfg, @0x1);
    transfer::public_transfer(cap, @0x1);
}

#[test]
fun adapter_accounting_helpers_work_when_configured() {
    let mut ctx = tx_context::dummy();
    let (mut cfg, cap) = config::new(0, 0, &mut ctx);

    config::set_lending_market_id(&mut cfg, &cap, @0x222);
    config::set_perps_market_id(&mut cfg, &cap, @0x333);
    config::set_flashloan_provider_id(&mut cfg, &cap, @0x444);

    let receipt = yield_source::deposit_to_lending(&cfg, 5_000);
    assert!(receipt == @0x222, 0);
    assert!(yield_source::accrue_yield(&cfg, 5_000) == 5_001, 0);

    let (next_receipt, withdrawn, remaining) = yield_source::withdraw_from_lending(&cfg, receipt, 5_001, 2_000);
    assert!(next_receipt == @0x222, 0);
    assert!(withdrawn == 2_000, 0);
    assert!(remaining == 3_001, 0);

    let (position_id, margin) = perp_hedge::open_short(&cfg, 3_700);
    assert!(position_id == @0x333, 0);
    assert!(margin == 185, 0);

    let (adjusted_id, adjusted_margin, changed) = perp_hedge::adjust_position(&cfg, position_id, 2_000);
    assert!(adjusted_id == @0x333, 0);
    assert!(adjusted_margin == 100, 0);
    assert!(changed, 0);

    assert!(rebalancer::rebalance_ptb(&cfg, 2_000), 0);
    assert!(rebalancer::rebalance_flash(&cfg, 2_500), 0);

    transfer::public_transfer(cfg, @0x1);
    transfer::public_transfer(cap, @0x1);
}
