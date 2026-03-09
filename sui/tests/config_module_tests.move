module self_driving_yield::config_module_tests;

use self_driving_yield::config;
use self_driving_yield::errors;

#[test]
fun can_create_update_and_seal_config() {
    let mut ctx = tx_context::dummy();
    let (mut cfg, cap) = config::new(1000, 250, &mut ctx);

    assert!(config::min_cycle_interval_ms(&cfg) == 1000, 0);
    assert!(config::min_snapshot_interval_ms(&cfg) == 250, 0);
    assert!(config::cetus_pool_id(&cfg) == @0x0, 0);
    assert!(config::lending_market_id(&cfg) == @0x0, 0);
    assert!(config::perps_market_id(&cfg) == @0x0, 0);
    assert!(config::flashloan_provider_id(&cfg) == @0x0, 0);
    assert!(!config::is_frozen(&cfg), 0);

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

    config::seal(&mut cfg, &cap);
    assert!(config::is_frozen(&cfg), 0);

    transfer::public_transfer(cfg, @0x1);
    transfer::public_transfer(cap, @0x1);
}

#[test, expected_failure(abort_code = errors::E_CONFIG_FROZEN, location = self_driving_yield::config)]
fun sealed_config_rejects_updates() {
    let mut ctx = tx_context::dummy();
    let (mut cfg, cap) = config::new(1000, 250, &mut ctx);

    config::seal(&mut cfg, &cap);
    config::set_cetus_pool_id(&mut cfg, &cap, @0x111);

    transfer::public_transfer(cfg, @0x1);
    transfer::public_transfer(cap, @0x1);
}

#[test, expected_failure(abort_code = errors::E_CONFIG_FROZEN, location = self_driving_yield::config)]
fun sealed_config_rejects_interval_updates() {
    let mut ctx = tx_context::dummy();
    let (mut cfg, cap) = config::new(1000, 250, &mut ctx);

    config::seal(&mut cfg, &cap);
    config::set_min_cycle_interval_ms(&mut cfg, &cap, 2000);

    transfer::public_transfer(cfg, @0x1);
    transfer::public_transfer(cap, @0x1);
}

#[test, expected_failure(abort_code = errors::E_CONFIG_FROZEN, location = self_driving_yield::config)]
fun sealed_config_rejects_snapshot_interval_updates() {
    let mut ctx = tx_context::dummy();
    let (mut cfg, cap) = config::new(1000, 250, &mut ctx);

    config::seal(&mut cfg, &cap);
    config::set_min_snapshot_interval_ms(&mut cfg, &cap, 500);

    transfer::public_transfer(cfg, @0x1);
    transfer::public_transfer(cap, @0x1);
}

#[test, expected_failure(abort_code = errors::E_CONFIG_FROZEN, location = self_driving_yield::config)]
fun sealed_config_rejects_lending_updates() {
    let mut ctx = tx_context::dummy();
    let (mut cfg, cap) = config::new(1000, 250, &mut ctx);

    config::seal(&mut cfg, &cap);
    config::set_lending_market_id(&mut cfg, &cap, @0x222);

    transfer::public_transfer(cfg, @0x1);
    transfer::public_transfer(cap, @0x1);
}

#[test, expected_failure(abort_code = errors::E_CONFIG_FROZEN, location = self_driving_yield::config)]
fun sealed_config_rejects_perps_updates() {
    let mut ctx = tx_context::dummy();
    let (mut cfg, cap) = config::new(1000, 250, &mut ctx);

    config::seal(&mut cfg, &cap);
    config::set_perps_market_id(&mut cfg, &cap, @0x333);

    transfer::public_transfer(cfg, @0x1);
    transfer::public_transfer(cap, @0x1);
}

#[test, expected_failure(abort_code = errors::E_CONFIG_FROZEN, location = self_driving_yield::config)]
fun sealed_config_rejects_flashloan_updates() {
    let mut ctx = tx_context::dummy();
    let (mut cfg, cap) = config::new(1000, 250, &mut ctx);

    config::seal(&mut cfg, &cap);
    config::set_flashloan_provider_id(&mut cfg, &cap, @0x444);

    transfer::public_transfer(cfg, @0x1);
    transfer::public_transfer(cap, @0x1);
}

#[test, expected_failure(abort_code = errors::E_CONFIG_FROZEN, location = self_driving_yield::config)]
fun sealed_config_cannot_be_sealed_twice() {
    let mut ctx = tx_context::dummy();
    let (mut cfg, cap) = config::new(1000, 250, &mut ctx);

    config::seal(&mut cfg, &cap);
    config::seal(&mut cfg, &cap);

    transfer::public_transfer(cfg, @0x1);
    transfer::public_transfer(cap, @0x1);
}
