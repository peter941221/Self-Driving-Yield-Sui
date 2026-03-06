module self_driving_yield::config_module_tests;

use self_driving_yield::config;

#[test]
fun can_create_and_update_config() {
    let mut ctx = tx_context::dummy();
    let (mut cfg, cap) = config::new(1000, 250, &mut ctx);

    assert!(config::min_cycle_interval_ms(&cfg) == 1000, 0);
    assert!(config::min_snapshot_interval_ms(&cfg) == 250, 0);
    assert!(config::cetus_pool_id(&cfg) == @0x0, 0);
    assert!(config::lending_market_id(&cfg) == @0x0, 0);
    assert!(config::perps_market_id(&cfg) == @0x0, 0);
    assert!(config::flashloan_provider_id(&cfg) == @0x0, 0);
    config::set_min_cycle_interval_ms(&mut cfg, &cap, 2000);
    config::set_min_snapshot_interval_ms(&mut cfg, &cap, 500);
    config::set_cetus_pool_id(&mut cfg, &cap, @0x111);
    config::set_lending_market_id(&mut cfg, &cap, @0x222);
    config::set_perps_market_id(&mut cfg, &cap, @0x333);
    config::set_flashloan_provider_id(&mut cfg, &cap, @0x444);
    assert!(config::min_cycle_interval_ms(&cfg) == 2000, 0);
    assert!(config::min_snapshot_interval_ms(&cfg) == 500, 0);
    assert!(config::cetus_pool_id(&cfg) == @0x111, 0);
    assert!(config::lending_market_id(&cfg) == @0x222, 0);
    assert!(config::perps_market_id(&cfg) == @0x333, 0);
    assert!(config::flashloan_provider_id(&cfg) == @0x444, 0);

    // Consume key objects to satisfy no-drop restriction in unit tests.
    transfer::public_transfer(cfg, @0x1);
    transfer::public_transfer(cap, @0x1);
}
