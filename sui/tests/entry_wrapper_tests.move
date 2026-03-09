module self_driving_yield::entry_wrapper_tests;

use sui::clock;
use sui::coin;
use sui::test_scenario;

use self_driving_yield::config;
use self_driving_yield::entrypoints;
use self_driving_yield::queue;
use self_driving_yield::sdye;
use self_driving_yield::usdc;

#[test]
fun deposit_and_instant_withdraw_entry_transfer_to_sender() {
    let admin = @0x1;
    let mut scenario = test_scenario::begin(admin);
    test_scenario::create_system_objects(&mut scenario);

    {
        let sdye_treasury = coin::create_treasury_cap_for_testing<sdye::SDYE>(test_scenario::ctx(&mut scenario));
        entrypoints::bootstrap<usdc::USDC>(sdye_treasury, 0, 0, test_scenario::ctx(&mut scenario));
    };
    test_scenario::next_tx(&mut scenario, admin);

    {
        let mut clock = test_scenario::take_shared<clock::Clock>(&scenario);
        clock::set_for_testing(&mut clock, 1000);

        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        entrypoints::deposit_entry(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        assert!(entrypoints::total_assets(&v) == 10_000, 0);
        assert!(entrypoints::total_shares(&v) == 10_000, 0);
        assert!(entrypoints::treasury_usdc(&v) == 10_000, 0);
        assert!(!entrypoints::is_only_unwind_mode(&v), 0);
        assert!(entrypoints::safe_cycles_since_storm(&v) == 2, 0);

        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
    };
    test_scenario::next_tx(&mut scenario, admin);

    {
        let mut clock = test_scenario::take_shared<clock::Clock>(&scenario);
        clock::set_for_testing(&mut clock, 2000);

        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let shares = test_scenario::take_from_sender<coin::Coin<sdye::SDYE>>(&scenario);
        assert!(coin::value(&shares) == 10_000, 0);

        entrypoints::request_withdraw_entry(&mut v, &mut q, shares, &clock, test_scenario::ctx(&mut scenario));
        assert!(entrypoints::total_assets(&v) == 0, 0);
        assert!(entrypoints::total_shares(&v) == 0, 0);
        assert!(entrypoints::treasury_usdc(&v) == 0, 0);

        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
    };
    test_scenario::next_tx(&mut scenario, admin);

    {
        let base_out = test_scenario::take_from_sender<coin::Coin<usdc::USDC>>(&scenario);
        assert!(coin::value(&base_out) == 10_000, 0);
        transfer::public_transfer(base_out, admin);
    };

    let _effects = test_scenario::end(scenario);
}

#[test]
fun cycle_entry_transfers_bounty_to_sender() {
    let admin = @0x1;
    let mut scenario = test_scenario::begin(admin);
    test_scenario::create_system_objects(&mut scenario);

    {
        let sdye_treasury = coin::create_treasury_cap_for_testing<sdye::SDYE>(test_scenario::ctx(&mut scenario));
        entrypoints::bootstrap<usdc::USDC>(sdye_treasury, 0, 0, test_scenario::ctx(&mut scenario));
    };
    test_scenario::next_tx(&mut scenario, admin);

    {
        let mut clock = test_scenario::take_shared<clock::Clock>(&scenario);
        clock::set_for_testing(&mut clock, 1000);

        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        config::set_cetus_pool_id(&mut cfg, &cap, @0x111);

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        entrypoints::deposit_entry(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));

        test_scenario::return_to_sender(&scenario, cap);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };
    test_scenario::next_tx(&mut scenario, admin);

    {
        let mut clock = test_scenario::take_shared<clock::Clock>(&scenario);
        clock::set_for_testing(&mut clock, 2000);

        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);
        let shares = test_scenario::take_from_sender<coin::Coin<sdye::SDYE>>(&scenario);
        assert!(coin::value(&shares) == 10_000, 0);
        transfer::public_transfer(shares, admin);

        entrypoints::cycle_entry(
            &mut v,
            &mut q,
            &cfg,
            1_000_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(entrypoints::has_cetus_position(&v), 0);
        assert!(entrypoints::cetus_pool_id(&v) == @0x111, 0);
        assert!(entrypoints::cetus_deployed_usdc(&v) == 3_698, 0);
        assert!(!entrypoints::is_only_unwind_mode(&v), 0);
        assert!(entrypoints::safe_cycles_since_storm(&v) == 2, 0);

        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };
    test_scenario::next_tx(&mut scenario, admin);

    {
        let bounty = test_scenario::take_from_sender<coin::Coin<usdc::USDC>>(&scenario);
        assert!(coin::value(&bounty) == 5, 0);
        transfer::public_transfer(bounty, admin);
    };

    let _effects = test_scenario::end(scenario);
}

#[test]
fun queued_withdraw_cycle_and_claim_entry_transfer_to_sender() {
    let admin = @0x1;
    let mut scenario = test_scenario::begin(admin);
    test_scenario::create_system_objects(&mut scenario);

    {
        let sdye_treasury = coin::create_treasury_cap_for_testing<sdye::SDYE>(test_scenario::ctx(&mut scenario));
        entrypoints::bootstrap<usdc::USDC>(sdye_treasury, 0, 0, test_scenario::ctx(&mut scenario));
    };
    test_scenario::next_tx(&mut scenario, admin);

    {
        let mut clock = test_scenario::take_shared<clock::Clock>(&scenario);
        clock::set_for_testing(&mut clock, 1000);

        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        entrypoints::deposit_entry(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));

        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
    };
    test_scenario::next_tx(&mut scenario, admin);

    {
        let mut clock = test_scenario::take_shared<clock::Clock>(&scenario);
        clock::set_for_testing(&mut clock, 2000);

        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut shares = test_scenario::take_from_sender<coin::Coin<sdye::SDYE>>(&scenario);

        entrypoints::deploy_for_testing(&mut v, 9_000);
        let withdraw_shares = coin::split(&mut shares, 5_000, test_scenario::ctx(&mut scenario));
        entrypoints::request_withdraw_entry(
            &mut v,
            &mut q,
            withdraw_shares,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        transfer::public_transfer(shares, admin);

        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
    };
    test_scenario::next_tx(&mut scenario, admin);

    {
        let mut clock = test_scenario::take_shared<clock::Clock>(&scenario);
        clock::set_for_testing(&mut clock, 3000);

        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);

        entrypoints::cycle_entry(
            &mut v,
            &mut q,
            &cfg,
            1_000_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        entrypoints::claim_entry(&mut v, &mut q, 0, &clock, test_scenario::ctx(&mut scenario));
        assert!(entrypoints::total_assets(&v) == 5_000, 0);
        assert!(entrypoints::total_shares(&v) == 5_000, 0);
        assert!(entrypoints::treasury_usdc(&v) == 0, 0);
        assert!(entrypoints::deployed_balance(&v) == 5_000, 0);
        assert!(!entrypoints::is_only_unwind_mode(&v), 0);
        assert!(entrypoints::safe_cycles_since_storm(&v) == 2, 0);

        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };
    test_scenario::next_tx(&mut scenario, admin);

    {
        let base_out = test_scenario::take_from_sender<coin::Coin<usdc::USDC>>(&scenario);
        assert!(coin::value(&base_out) == 5_000, 0);
        transfer::public_transfer(base_out, admin);
    };

    let _effects = test_scenario::end(scenario);
}

#[test]
fun cycle_with_confidence_entry_keeps_risk_more_conservative() {
    let admin = @0x1;
    let mut scenario = test_scenario::begin(admin);
    test_scenario::create_system_objects(&mut scenario);

    {
        let sdye_treasury = coin::create_treasury_cap_for_testing<sdye::SDYE>(test_scenario::ctx(&mut scenario));
        entrypoints::bootstrap<usdc::USDC>(sdye_treasury, 0, 0, test_scenario::ctx(&mut scenario));
    };
    test_scenario::next_tx(&mut scenario, admin);

    {
        let mut clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        entrypoints::deposit_entry(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));

        let mut ts: u64 = 0;
        let mut i: u64 = 0;
        while (i < 12) {
            ts = ts + 1000;
            clock::set_for_testing(&mut clock, ts);
            entrypoints::cycle_with_confidence_entry(
                &mut v,
                &mut q,
                &cfg,
                1_000_000_000,
                25,
                &clock,
                test_scenario::ctx(&mut scenario),
            );
            i = i + 1;
        };
        assert!(!entrypoints::is_only_unwind_mode(&v), 0);
        assert!(entrypoints::safe_cycles_since_storm(&v) == 2, 0);

        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    test_scenario::next_tx(&mut scenario, admin);
    {
        let shares = test_scenario::take_from_sender<coin::Coin<sdye::SDYE>>(&scenario);
        transfer::public_transfer(shares, admin);
    };

    let _effects = test_scenario::end(scenario);
}

#[test]
fun guarded_normal_cycle_helper_restores_only_unwind() {
    let admin = @0x1;
    let mut scenario = test_scenario::begin(admin);
    test_scenario::create_system_objects(&mut scenario);

    {
        let sdye_treasury = coin::create_treasury_cap_for_testing<sdye::SDYE>(test_scenario::ctx(&mut scenario));
        entrypoints::bootstrap<usdc::USDC>(sdye_treasury, 0, 0, test_scenario::ctx(&mut scenario));
    };
    test_scenario::next_tx(&mut scenario, admin);

    {
        let mut clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        entrypoints::deposit_entry(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));

        let p = 1_000_000_000;
        let mut storm_price = p;
        let mut ts: u64 = 0;
        let mut i: u64 = 0;
        while (i < 12) {
            ts = ts + 1000;
            clock::set_for_testing(&mut clock, ts);
            entrypoints::cycle_entry(&mut v, &mut q, &cfg, storm_price, &clock, test_scenario::ctx(&mut scenario));
            storm_price = ((storm_price as u128) * 10300 / 10000) as u64;
            i = i + 1;
        };

        assert!(entrypoints::is_only_unwind_mode(&v), 0);
        entrypoints::apply_guarded_normal_cycle_for_testing(&mut v, 0, 0, 0);
        assert!(entrypoints::safe_cycles_since_storm(&v) == 1, 0);
        entrypoints::apply_guarded_normal_cycle_for_testing(&mut v, 0, 0, 0);
        assert!(!entrypoints::is_only_unwind_mode(&v), 0);

        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    test_scenario::next_tx(&mut scenario, admin);
    {
        let shares = test_scenario::take_from_sender<coin::Coin<sdye::SDYE>>(&scenario);
        transfer::public_transfer(shares, admin);
    };

    let _effects = test_scenario::end(scenario);
}

#[test]
fun cycle_with_confidence_non_entry_keeps_bounty_optional_surface() {
    let admin = @0x1;
    let mut scenario = test_scenario::begin(admin);
    test_scenario::create_system_objects(&mut scenario);

    {
        let sdye_treasury = coin::create_treasury_cap_for_testing<sdye::SDYE>(test_scenario::ctx(&mut scenario));
        entrypoints::bootstrap<usdc::USDC>(sdye_treasury, 0, 0, test_scenario::ctx(&mut scenario));
    };
    test_scenario::next_tx(&mut scenario, admin);

    {
        let mut clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        entrypoints::deposit_entry(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 1_000);
        let (_, bounty_opt) = entrypoints::cycle_with_confidence(&mut v, &mut q, &cfg, 1_000_000_000, 15, &clock, test_scenario::ctx(&mut scenario));
        assert!(option::is_some(&bounty_opt), 0);
        let bounty = option::destroy_some(bounty_opt);
        assert!(coin::value(&bounty) > 0, 0);
        transfer::public_transfer(bounty, admin);

        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    test_scenario::next_tx(&mut scenario, admin);
    {
        let shares = test_scenario::take_from_sender<coin::Coin<sdye::SDYE>>(&scenario);
        transfer::public_transfer(shares, admin);
    };

    let _effects = test_scenario::end(scenario);
}
