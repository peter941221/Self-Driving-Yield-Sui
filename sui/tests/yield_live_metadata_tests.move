module self_driving_yield::yield_live_metadata_tests;

use sui::coin;
use sui::test_scenario;

use self_driving_yield::config;
use self_driving_yield::entrypoints;
use self_driving_yield::sdye;
use self_driving_yield::usdc;
use self_driving_yield::yield_source;

#[test]
fun live_yield_metadata_tracks_deposit_hold_and_withdraw() {
    let admin = @0x1;
    let mut scenario = test_scenario::begin(admin);
    test_scenario::create_system_objects(&mut scenario);

    {
        let sdye_treasury = coin::create_treasury_cap_for_testing<sdye::SDYE>(test_scenario::ctx(&mut scenario));
        entrypoints::bootstrap<usdc::USDC>(sdye_treasury, 0, 0, test_scenario::ctx(&mut scenario));
    };
    test_scenario::next_tx(&mut scenario, admin);

    {
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        config::set_lending_market_id(&mut cfg, &cap, @0x222);

        entrypoints::record_live_yield_deposit(&mut v, &cfg, @0xabc, 5_000, 5_100, 1_000);
        assert!(entrypoints::live_yield_enabled(&v), 0);
        assert!(entrypoints::live_yield_position_present(&v), 0);
        assert!(entrypoints::live_yield_last_market_id(&v) == @0x222, 0);
        assert!(entrypoints::live_yield_last_receipt_id(&v) == @0xabc, 0);
        assert!(entrypoints::live_yield_last_principal(&v) == 5_000, 0);
        assert!(entrypoints::live_yield_last_value(&v) == 5_100, 0);
        assert!(entrypoints::live_yield_last_snapshot_ts_ms(&v) == 1_000, 0);
        assert!(entrypoints::live_yield_last_action_code(&v) == yield_source::live_yield_action_deposit(), 0);
        assert!(entrypoints::yield_receipt_id(&v) == @0xabc, 0);

        entrypoints::record_live_yield_hold(&mut v, &cfg, @0xabc, 5_250, 2_000);
        assert!(entrypoints::live_yield_last_receipt_id(&v) == @0xabc, 0);
        assert!(entrypoints::live_yield_last_principal(&v) == 5_000, 0);
        assert!(entrypoints::live_yield_last_value(&v) == 5_250, 0);
        assert!(entrypoints::live_yield_last_snapshot_ts_ms(&v) == 2_000, 0);
        assert!(entrypoints::live_yield_last_action_code(&v) == yield_source::live_yield_action_hold(), 0);

        entrypoints::record_live_yield_withdraw(&mut v, &cfg, @0xabc, 2_000, 3_250, 3_000);
        assert!(entrypoints::live_yield_position_present(&v), 0);
        assert!(entrypoints::live_yield_last_receipt_id(&v) == @0xabc, 0);
        assert!(entrypoints::live_yield_last_principal(&v) == 3_096, 0);
        assert!(entrypoints::live_yield_last_value(&v) == 3_250, 0);
        assert!(entrypoints::live_yield_last_action_code(&v) == yield_source::live_yield_action_withdraw_partial(), 0);

        entrypoints::record_live_yield_withdraw(&mut v, &cfg, @0xabc, 3_250, 0, 4_000);
        assert!(!entrypoints::live_yield_position_present(&v), 0);
        assert!(entrypoints::live_yield_last_receipt_id(&v) == @0x0, 0);
        assert!(entrypoints::live_yield_last_principal(&v) == 0, 0);
        assert!(entrypoints::live_yield_last_value(&v) == 0, 0);
        assert!(entrypoints::live_yield_last_snapshot_ts_ms(&v) == 4_000, 0);
        assert!(entrypoints::live_yield_last_action_code(&v) == yield_source::live_yield_action_withdraw_full(), 0);
        assert!(entrypoints::yield_receipt_id(&v) == @0x0, 0);

        test_scenario::return_shared(v);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
    };

    test_scenario::end(scenario);
}

#[test]
fun live_yield_entry_wrappers_update_metadata() {
    let admin = @0x1;
    let mut scenario = test_scenario::begin(admin);
    test_scenario::create_system_objects(&mut scenario);

    {
        let sdye_treasury = coin::create_treasury_cap_for_testing<sdye::SDYE>(test_scenario::ctx(&mut scenario));
        entrypoints::bootstrap<usdc::USDC>(sdye_treasury, 0, 0, test_scenario::ctx(&mut scenario));
    };
    test_scenario::next_tx(&mut scenario, admin);

    {
        let mut clock = test_scenario::take_shared<sui::clock::Clock>(&scenario);
        sui::clock::set_for_testing(&mut clock, 5_000);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        config::set_lending_market_id(&mut cfg, &cap, @0x222);
        entrypoints::sync_live_yield_deposit_entry(&mut v, &cfg, &cap, @0xabc, 1_000, 1_050, &clock);
        assert!(entrypoints::live_yield_last_action_code(&v) == yield_source::live_yield_action_deposit(), 0);

        sui::clock::set_for_testing(&mut clock, 6_000);
        entrypoints::sync_live_yield_hold_entry(&mut v, &cfg, &cap, @0xabc, 1_100, &clock);
        assert!(entrypoints::live_yield_last_action_code(&v) == yield_source::live_yield_action_hold(), 0);

        sui::clock::set_for_testing(&mut clock, 7_000);
        entrypoints::sync_live_yield_withdraw_entry(&mut v, &cfg, &cap, @0xabc, 1_100, 0, &clock);
        assert!(entrypoints::live_yield_last_action_code(&v) == yield_source::live_yield_action_withdraw_full(), 0);
        assert!(!entrypoints::live_yield_position_present(&v), 0);

        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
    };

    test_scenario::end(scenario);
}
