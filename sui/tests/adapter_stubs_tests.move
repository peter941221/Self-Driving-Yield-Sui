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
