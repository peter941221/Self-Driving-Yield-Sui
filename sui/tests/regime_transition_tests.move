module self_driving_yield::regime_transition_tests;

use sui::clock;
use sui::coin;
use sui::test_scenario;

use self_driving_yield::config;
use self_driving_yield::entrypoints;
use self_driving_yield::oracle;
use self_driving_yield::queue;
use self_driving_yield::sdye;
use self_driving_yield::usdc;

fun transfer_bounty_if_any<BASE>(bounty_opt: option::Option<coin::Coin<BASE>>, recipient: address) {
    if (option::is_some(&bounty_opt)) {
        let bounty = option::destroy_some(bounty_opt);
        transfer::public_transfer(bounty, recipient);
    } else {
        option::destroy_none(bounty_opt);
    };
}

#[test]
fun calm_regime_rebalances_toward_yield_bucket() {
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
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        config::set_cetus_pool_id(&mut cfg, &cap, @0x111);
        config::set_lending_market_id(&mut cfg, &cap, @0x222);
        config::set_perps_market_id(&mut cfg, &cap, @0x333);
        config::set_flashloan_provider_id(&mut cfg, &cap, @0x444);

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, admin);

        let p = oracle::price_precision();
        let hi = p + 9_900_000;
        let lo = p - 9_900_000;
        let mut ts: u64 = 0;
        let mut i: u64 = 0;
        while (i < 12) {
            ts = ts + 1000;
            clock::set_for_testing(&mut clock, ts);
            let price = if (i % 2 == 0) { hi } else { lo };
            let (_, bounty_opt) = entrypoints::cycle(
                &mut v,
                &mut q,
                &cfg,
                price,
                &clock,
                test_scenario::ctx(&mut scenario),
            );
            transfer_bounty_if_any(bounty_opt, admin);
            i = i + 1;
        };

        assert!(!entrypoints::is_only_unwind_mode(&v), 0);
        assert!(entrypoints::cetus_deployed_usdc(&v) > entrypoints::yield_deployed_usdc(&v), 0);
        assert!(entrypoints::yield_receipt_id(&v) == @0x222, 0);
        assert!(entrypoints::safe_cycles_since_storm(&v) == 2, 0);

        test_scenario::return_to_sender(&scenario, cap);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    let _effects = test_scenario::end(scenario);
}

#[test]
fun storm_only_unwind_keeps_yield_but_unwinds_lp_and_hedge() {
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
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        config::set_cetus_pool_id(&mut cfg, &cap, @0x111);
        config::set_lending_market_id(&mut cfg, &cap, @0x222);
        config::set_perps_market_id(&mut cfg, &cap, @0x333);
        config::set_flashloan_provider_id(&mut cfg, &cap, @0x444);

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, admin);

        let p = oracle::price_precision();
        let hi = p + 30_000_000;
        let lo = p - 30_000_000;
        let mut ts: u64 = 0;
        let mut i: u64 = 0;
        while (i < 12) {
            ts = ts + 1000;
            clock::set_for_testing(&mut clock, ts);
            let price = if (i % 2 == 0) { hi } else { lo };
            let (_, bounty_opt) = entrypoints::cycle(
                &mut v,
                &mut q,
                &cfg,
                price,
                &clock,
                test_scenario::ctx(&mut scenario),
            );
            transfer_bounty_if_any(bounty_opt, admin);
            i = i + 1;
        };

        assert!(entrypoints::is_only_unwind_mode(&v), 0);
        assert!(entrypoints::yield_deployed_usdc(&v) > 0, 0);
        assert!(entrypoints::yield_receipt_id(&v) == @0x222, 0);
        assert!(entrypoints::cetus_deployed_usdc(&v) == 0, 0);
        assert!(entrypoints::cetus_pool_id(&v) == @0x0, 0);
        assert!(entrypoints::hedge_margin_usdc(&v) == 0, 0);
        assert!(entrypoints::hedge_position_id(&v) == @0x0, 0);
        assert!(entrypoints::safe_cycles_since_storm(&v) == 0, 0);

        test_scenario::return_to_sender(&scenario, cap);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    let _effects = test_scenario::end(scenario);
}

#[test]
fun storm_only_unwind_without_yield_config_unwinds_everything() {
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
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, admin);

        entrypoints::deploy_for_testing(&mut v, 9_000);

        let p = oracle::price_precision();
        let hi = p + 30_000_000;
        let lo = p - 30_000_000;
        let mut ts: u64 = 0;
        let mut i: u64 = 0;
        while (i < 12) {
            ts = ts + 1000;
            clock::set_for_testing(&mut clock, ts);
            let price = if (i % 2 == 0) { hi } else { lo };
            let (_, bounty_opt) = entrypoints::cycle(
                &mut v,
                &mut q,
                &cfg,
                price,
                &clock,
                test_scenario::ctx(&mut scenario),
            );
            transfer_bounty_if_any(bounty_opt, admin);
            i = i + 1;
        };

        assert!(entrypoints::is_only_unwind_mode(&v), 0);
        assert!(entrypoints::yield_deployed_usdc(&v) == 0, 0);
        assert!(entrypoints::cetus_pool_id(&v) == @0x0, 0);
        assert!(entrypoints::hedge_margin_usdc(&v) == 0, 0);
        assert!(entrypoints::deployed_balance(&v) <= 9_000, 0);
        assert!(entrypoints::treasury_usdc(&v) > 0, 0);
        assert!(entrypoints::safe_cycles_since_storm(&v) == 0, 0);

        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    let _effects = test_scenario::end(scenario);
}


