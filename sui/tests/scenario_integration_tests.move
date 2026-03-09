module self_driving_yield::scenario_integration_tests;

use sui::clock;
use sui::coin;
use sui::test_scenario;

use self_driving_yield::config;
use self_driving_yield::sdye;
use self_driving_yield::entrypoints;
use self_driving_yield::oracle;
use self_driving_yield::usdc;
use self_driving_yield::queue;
use self_driving_yield::vault;

fun assert_balance_invariant(v: &entrypoints::Vault<usdc::USDC>) {
    assert!(
        entrypoints::total_assets(v) == entrypoints::treasury_usdc(v) + entrypoints::deployed_balance(v),
        0,
    );
}

fun active_locked_shares(q: &queue::WithdrawalQueue, max_id: u64): u64 {
    let mut total = 0;
    let mut i = 0;
    while (i < max_id) {
        let req = queue::borrow_request(queue::state(q), i);
        let st = queue::status(req);
        if (!queue::is_claimed(&st)) {
            total = total + queue::shares(req);
        };
        i = i + 1;
    };
    total
}

#[test]
fun deposit_cycle_withdraw_claim_full_path() {
    let admin = @0x1;
    let mut scenario = test_scenario::begin(admin);
    test_scenario::create_system_objects(&mut scenario);

    // Tx1: init shared objects + create mock USDC currency cap.
    {
        let sdye_treasury = coin::create_treasury_cap_for_testing<sdye::SDYE>(test_scenario::ctx(&mut scenario));
        entrypoints::bootstrap<usdc::USDC>(sdye_treasury, 0, 0, test_scenario::ctx(&mut scenario));
    };
    test_scenario::next_tx(&mut scenario, admin);

    // Tx2: deposit + deploy most funds (to force queued withdrawal) + request_withdraw.
    {
        let mut clock = test_scenario::take_shared<clock::Clock>(&scenario);
        clock::set_for_testing(&mut clock, 1000);

        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);

        let cfg = test_scenario::take_shared<config::Config>(&scenario);
        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let mut shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));

        // Make treasury liquid insufficient, simulating assets deployed in adapters.
        entrypoints::deploy_for_testing(&mut v, 9_000);

        // Withdraw 5_000 shares => queued (treasury liquid is only 1_000).
        let withdraw_shares = coin::split(&mut shares, 5_000, test_scenario::ctx(&mut scenario));
        let (plan, base_opt) =
            entrypoints::request_withdraw(&mut v, &mut q, withdraw_shares, &clock, test_scenario::ctx(&mut scenario));
        assert!(vault::plan_is_queued(&plan), 0);
        assert!(option::is_none(&base_opt), 0);
        option::destroy_none(base_opt);

        // Persist remaining shares + owned objects.
        transfer::public_transfer(shares, admin);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };
    test_scenario::next_tx(&mut scenario, admin);

    // Tx3: cycle twice (multi-cycle), then claim.
    {
        let mut clock = test_scenario::take_shared<clock::Clock>(&scenario);
        clock::set_for_testing(&mut clock, 2000);

        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);

        let (moved, bounty_opt) = entrypoints::cycle(
            &mut v,
            &mut q,
            &cfg,
            1_000_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(moved == 1, 0);
        assert!(option::is_none(&bounty_opt), 0);
        option::destroy_none(bounty_opt);

        clock::set_for_testing(&mut clock, 3000);
        let (moved2, bounty_opt2) = entrypoints::cycle(
            &mut v,
            &mut q,
            &cfg,
            1_000_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(moved2 == 0, 0);
        assert!(option::is_none(&bounty_opt2), 0);
        option::destroy_none(bounty_opt2);

        let base_out = entrypoints::claim(&mut v, &mut q, 0, &clock, test_scenario::ctx(&mut scenario));
        assert!(coin::value(&base_out) == 5_000, 0);
        transfer::public_transfer(base_out, admin);

        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    let _effects = test_scenario::end(scenario);
}

#[test]
fun storm_queue_pressure_unwinds_and_restores_after_two_safe_cycles() {
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
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);

        let usdc_in = coin::mint_for_testing<usdc::USDC>(20_000, test_scenario::ctx(&mut scenario));
        let mut shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        entrypoints::deploy_for_testing(&mut v, 18_000);

        let withdraw_a = coin::split(&mut shares, 7_000, test_scenario::ctx(&mut scenario));
        let (plan_a, base_opt_a) = entrypoints::request_withdraw(&mut v, &mut q, withdraw_a, &clock, test_scenario::ctx(&mut scenario));
        assert!(vault::plan_is_queued(&plan_a), 0);
        assert!(vault::queued_request_id(&plan_a) == 0, 0);
        option::destroy_none(base_opt_a);

        let withdraw_b = coin::split(&mut shares, 8_000, test_scenario::ctx(&mut scenario));
        let (plan_b, base_opt_b) = entrypoints::request_withdraw(&mut v, &mut q, withdraw_b, &clock, test_scenario::ctx(&mut scenario));
        assert!(vault::plan_is_queued(&plan_b), 0);
        assert!(vault::queued_request_id(&plan_b) == 1, 0);
        option::destroy_none(base_opt_b);

        assert!(queue::total_pending_usdc(queue::state(&q)) == 15_000, 0);
        assert!(active_locked_shares(&q, 2) == 15_000, 0);
        assert_balance_invariant(&v);

        transfer::public_transfer(shares, admin);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };
    test_scenario::next_tx(&mut scenario, admin);

    {
        let mut clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);

        let p = oracle::price_precision();
        let mut ts = 2000;
        let mut i = 0;
        let mut storm_price = p;
        while (i < 12u64) {
            clock::set_for_testing(&mut clock, ts);
            let (_, bounty_opt) = entrypoints::cycle(&mut v, &mut q, &cfg, storm_price, &clock, test_scenario::ctx(&mut scenario));
            option::destroy_none(bounty_opt);
            storm_price = ((storm_price as u128) * 10300 / 10000) as u64;
            ts = ts + 1000;
            i = i + 1;
        };

        assert!(entrypoints::is_only_unwind_mode(&v), 0);
        assert!(entrypoints::safe_cycles_since_storm(&v) == 0, 0);
        assert!(queue::total_ready_usdc(queue::state(&q)) == 15_000, 0);
        assert!(queue::total_pending_usdc(queue::state(&q)) == 0, 0);
        assert!(entrypoints::treasury_usdc(&v) == 15_000, 0);
        assert!(entrypoints::deployed_balance(&v) == 5_000, 0);
        assert_balance_invariant(&v);

        let out_a = entrypoints::claim(&mut v, &mut q, 0, &clock, test_scenario::ctx(&mut scenario));
        let out_b = entrypoints::claim(&mut v, &mut q, 1, &clock, test_scenario::ctx(&mut scenario));
        assert!(coin::value(&out_a) == 7_000, 0);
        assert!(coin::value(&out_b) == 8_000, 0);
        transfer::public_transfer(out_a, admin);
        transfer::public_transfer(out_b, admin);
        assert!(queue::total_ready_usdc(queue::state(&q)) == 0, 0);
        assert!(entrypoints::treasury_usdc(&v) == 0, 0);

        entrypoints::apply_guarded_normal_cycle_for_testing(&mut v, 0, 0, 0);

        assert!(entrypoints::is_only_unwind_mode(&v), 0);
        assert!(entrypoints::safe_cycles_since_storm(&v) == 1, 0);

        entrypoints::apply_guarded_normal_cycle_for_testing(&mut v, 0, 0, 0);
        assert!(!entrypoints::is_only_unwind_mode(&v), 0);
        assert!(entrypoints::safe_cycles_since_storm(&v) == 2, 0);

        assert!(queue::total_ready_usdc(queue::state(&q)) == 0, 0);
        assert!(active_locked_shares(&q, 2) == 0, 0);
        assert!(entrypoints::total_shares(&v) == 5_000, 0);
        assert!(entrypoints::treasury_usdc(&v) == 0, 0);
        assert!(entrypoints::deployed_balance(&v) == 5_000, 0);
        assert_balance_invariant(&v);

        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    let _effects = test_scenario::end(scenario);
}

#[test]
fun instant_withdraw_returns_base_coin() {
    let admin = @0x1;
    let mut scenario = test_scenario::begin(admin);
    test_scenario::create_system_objects(&mut scenario);

    // Tx1: bootstrap shared objects.
    {
        let sdye_treasury = coin::create_treasury_cap_for_testing<sdye::SDYE>(test_scenario::ctx(&mut scenario));
        entrypoints::bootstrap<usdc::USDC>(sdye_treasury, 0, 0, test_scenario::ctx(&mut scenario));
    };
    test_scenario::next_tx(&mut scenario, admin);

    // Tx2: deposit then instant withdraw.
    {
        let mut clock = test_scenario::take_shared<clock::Clock>(&scenario);
        clock::set_for_testing(&mut clock, 1000);

        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);

        let cfg = test_scenario::take_shared<config::Config>(&scenario);

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let mut shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));

        let withdraw_shares = coin::split(&mut shares, 3_000, test_scenario::ctx(&mut scenario));
        let (plan, base_opt) =
            entrypoints::request_withdraw(&mut v, &mut q, withdraw_shares, &clock, test_scenario::ctx(&mut scenario));
        assert!(vault::plan_is_instant(&plan), 0);

        let base_out = option::destroy_some(base_opt);
        assert!(coin::value(&base_out) == 3_000, 0);
        transfer::public_transfer(base_out, admin);

        transfer::public_transfer(shares, admin);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    let _effects = test_scenario::end(scenario);
}

#[test]
fun cycle_pays_bounty_when_treasury_unreserved() {
    let admin = @0x1;
    let mut scenario = test_scenario::begin(admin);
    test_scenario::create_system_objects(&mut scenario);

    // Tx1: bootstrap shared objects.
    {
        let sdye_treasury = coin::create_treasury_cap_for_testing<sdye::SDYE>(test_scenario::ctx(&mut scenario));
        entrypoints::bootstrap<usdc::USDC>(sdye_treasury, 0, 0, test_scenario::ctx(&mut scenario));
    };
    test_scenario::next_tx(&mut scenario, admin);

    // Tx2: deposit then cycle => bounty.
    {
        let mut clock = test_scenario::take_shared<clock::Clock>(&scenario);
        clock::set_for_testing(&mut clock, 1000);

        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, admin);

        let (moved, bounty_opt) = entrypoints::cycle(
            &mut v,
            &mut q,
            &cfg,
            1_000_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(moved == 0, 0);

        let bounty = option::destroy_some(bounty_opt);
        assert!(coin::value(&bounty) == 5, 0);
        transfer::public_transfer(bounty, admin);

        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    let _effects = test_scenario::end(scenario);
}

#[test]
fun cycle_auto_deploys_to_cetus_and_unwinds_for_queue() {
    let admin = @0x1;
    let mut scenario = test_scenario::begin(admin);
    test_scenario::create_system_objects(&mut scenario);

    // Tx1: bootstrap shared objects.
    {
        let sdye_treasury = coin::create_treasury_cap_for_testing<sdye::SDYE>(test_scenario::ctx(&mut scenario));
        entrypoints::bootstrap<usdc::USDC>(sdye_treasury, 0, 0, test_scenario::ctx(&mut scenario));
    };
    test_scenario::next_tx(&mut scenario, admin);

    // Tx2: configure Cetus + deposit + first cycle => auto deploy to LP target.
    {
        let mut clock = test_scenario::take_shared<clock::Clock>(&scenario);
        clock::set_for_testing(&mut clock, 1000);

        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        config::set_cetus_pool_id(&mut cfg, &cap, @0x111);

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));

        let (moved, bounty_opt) = entrypoints::cycle(
            &mut v,
            &mut q,
            &cfg,
            1_000_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(moved == 0, 0);

        let bounty = option::destroy_some(bounty_opt);
        assert!(coin::value(&bounty) == 5, 0);
        transfer::public_transfer(bounty, admin);

        assert!(entrypoints::has_cetus_position(&v), 0);
        assert!(entrypoints::cetus_pool_id(&v) == @0x111, 0);
        assert!(entrypoints::cetus_deployed_usdc(&v) == 3698, 0);
        assert!(entrypoints::deployed_balance(&v) == 3698, 0);
        assert!(entrypoints::cetus_last_rebalance_ts_ms(&v) == 1000, 0);

        transfer::public_transfer(shares, admin);
        test_scenario::return_to_sender(&scenario, cap);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };
    test_scenario::next_tx(&mut scenario, admin);

    // Tx3: large withdrawal queues, next cycle unwinds just enough to satisfy it.
    {
        let mut clock = test_scenario::take_shared<clock::Clock>(&scenario);
        clock::set_for_testing(&mut clock, 2000);

        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);
        let mut shares = test_scenario::take_from_sender<coin::Coin<sdye::SDYE>>(&scenario);

        let withdraw_shares = coin::split(&mut shares, 8_000, test_scenario::ctx(&mut scenario));
        let (plan, base_opt) =
            entrypoints::request_withdraw(&mut v, &mut q, withdraw_shares, &clock, test_scenario::ctx(&mut scenario));
        assert!(vault::plan_is_queued(&plan), 0);
        assert!(vault::queued_usdc_amount(&plan) == 7_996, 0);
        assert!(option::is_none(&base_opt), 0);
        option::destroy_none(base_opt);

        let (moved, bounty_opt) = entrypoints::cycle(
            &mut v,
            &mut q,
            &cfg,
            1_000_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(moved == 1, 0);
        assert!(option::is_none(&bounty_opt), 0);
        option::destroy_none(bounty_opt);

        assert!(entrypoints::has_cetus_position(&v), 0);
        assert!(entrypoints::cetus_deployed_usdc(&v) == 1_999, 0);
        assert!(entrypoints::deployed_balance(&v) == 1_999, 0);
        assert!(entrypoints::cetus_last_rebalance_ts_ms(&v) == 2000, 0);

        transfer::public_transfer(shares, admin);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    let _effects = test_scenario::end(scenario);
}

#[test]
fun cycle_rebalances_full_p2_strategy_mix() {
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

        let (moved, bounty_opt) = entrypoints::cycle(
            &mut v,
            &mut q,
            &cfg,
            1_000_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(moved == 0, 0);

        let bounty = option::destroy_some(bounty_opt);
        assert!(coin::value(&bounty) == 5, 0);
        transfer::public_transfer(bounty, admin);

        assert!(entrypoints::cetus_pool_id(&v) == @0x111, 0);
        assert!(entrypoints::cetus_deployed_usdc(&v) == 3698, 0);
        assert!(entrypoints::yield_receipt_id(&v) == @0x222, 0);
        assert!(entrypoints::yield_deployed_usdc(&v) == 5813, 0);
        assert!(entrypoints::hedge_position_id(&v) == @0x333, 0);
        assert!(entrypoints::hedge_notional_usdc(&v) == 3698, 0);
        assert!(entrypoints::hedge_margin_usdc(&v) == 184, 0);
        assert!(entrypoints::deployed_balance(&v) == 9695, 0);
        assert!(entrypoints::last_rebalance_used_flash(&v), 0);

        test_scenario::return_to_sender(&scenario, cap);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    let _effects = test_scenario::end(scenario);
}

#[test]
fun full_queue_reserve_unwinds_all_p2_and_claim_succeeds() {
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

        let (moved, bounty_opt) = entrypoints::cycle(
            &mut v,
            &mut q,
            &cfg,
            1_000_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(moved == 0, 0);
        let bounty = option::destroy_some(bounty_opt);
        assert!(coin::value(&bounty) == 5, 0);
        transfer::public_transfer(bounty, admin);

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

        let (plan, base_opt) = entrypoints::request_withdraw(&mut v, &mut q, shares, &clock, test_scenario::ctx(&mut scenario));
        assert!(vault::plan_is_queued(&plan), 0);
        assert!(vault::queued_usdc_amount(&plan) == 9_995, 0);
        assert!(option::is_none(&base_opt), 0);
        option::destroy_none(base_opt);

        let (moved, bounty_opt) = entrypoints::cycle(
            &mut v,
            &mut q,
            &cfg,
            1_000_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(moved == 1, 0);
        assert!(option::is_none(&bounty_opt), 0);
        option::destroy_none(bounty_opt);

        assert!(queue::total_ready_usdc(queue::state(&q)) == 9_995, 0);
        assert!(queue::total_pending_usdc(queue::state(&q)) == 0, 0);
        assert!(entrypoints::cetus_deployed_usdc(&v) == 0, 0);
        assert!(entrypoints::yield_deployed_usdc(&v) == 0, 0);
        assert!(entrypoints::hedge_margin_usdc(&v) == 0, 0);
        assert!(entrypoints::deployed_balance(&v) == 0, 0);
        assert!(entrypoints::treasury_usdc(&v) == 9_995, 0);
        assert_balance_invariant(&v);

        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };
    test_scenario::next_tx(&mut scenario, admin);

    {
        let clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);

        let base_out = entrypoints::claim(&mut v, &mut q, 0, &clock, test_scenario::ctx(&mut scenario));
        assert!(coin::value(&base_out) == 9_995, 0);
        transfer::public_transfer(base_out, admin);
        assert!(entrypoints::total_assets(&v) == 0, 0);
        assert!(entrypoints::total_shares(&v) == 0, 0);
        assert!(entrypoints::treasury_usdc(&v) == 0, 0);
        assert!(entrypoints::deployed_balance(&v) == 0, 0);
        assert_balance_invariant(&v);

        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    let _effects = test_scenario::end(scenario);
}

#[test]
fun multi_user_queue_preserves_conservation_and_fairness() {
    let admin = @0x1;
    let user1 = @0x11;
    let user2 = @0x12;
    let user3 = @0x13;
    let user4 = @0x14;
    let user5 = @0x15;
    let mut scenario = test_scenario::begin(admin);
    test_scenario::create_system_objects(&mut scenario);

    {
        let sdye_treasury = coin::create_treasury_cap_for_testing<sdye::SDYE>(test_scenario::ctx(&mut scenario));
        entrypoints::bootstrap<usdc::USDC>(sdye_treasury, 0, 0, test_scenario::ctx(&mut scenario));
    };

    test_scenario::next_tx(&mut scenario, user1);
    {
        let clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);
        let usdc_in = coin::mint_for_testing<usdc::USDC>(1_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, user1);
        assert_balance_invariant(&v);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    test_scenario::next_tx(&mut scenario, user2);
    {
        let clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);
        let usdc_in = coin::mint_for_testing<usdc::USDC>(1_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, user2);
        assert_balance_invariant(&v);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    test_scenario::next_tx(&mut scenario, user3);
    {
        let clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);
        let usdc_in = coin::mint_for_testing<usdc::USDC>(1_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, user3);
        assert_balance_invariant(&v);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    test_scenario::next_tx(&mut scenario, user4);
    {
        let clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);
        let usdc_in = coin::mint_for_testing<usdc::USDC>(1_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, user4);
        assert_balance_invariant(&v);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    test_scenario::next_tx(&mut scenario, user5);
    {
        let clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);
        let usdc_in = coin::mint_for_testing<usdc::USDC>(1_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, user5);
        assert!(entrypoints::total_shares(&v) == 5_000, 0);
        assert_balance_invariant(&v);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);
        entrypoints::deploy_for_testing(&mut v, 4_500);
        assert!(entrypoints::treasury_usdc(&v) == 500, 0);
        assert_balance_invariant(&v);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    // Five users each queue 800 shares; remaining 200 shares each stay user-owned.
    test_scenario::next_tx(&mut scenario, user1);
    {
        let clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);
        let mut shares = test_scenario::take_from_sender<coin::Coin<sdye::SDYE>>(&scenario);
        let out = coin::split(&mut shares, 800, test_scenario::ctx(&mut scenario));
        let (plan, base_opt) = entrypoints::request_withdraw(&mut v, &mut q, out, &clock, test_scenario::ctx(&mut scenario));
        assert!(vault::plan_is_queued(&plan), 0);
        assert!(vault::queued_request_id(&plan) == 0, 0);
        option::destroy_none(base_opt);
        transfer::public_transfer(shares, user1);
        assert!(entrypoints::total_shares(&v) == 5_000, 0);
        assert!(active_locked_shares(&q, 1) == 800, 0);
        assert_balance_invariant(&v);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    test_scenario::next_tx(&mut scenario, user2);
    {
        let clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);
        let mut shares = test_scenario::take_from_sender<coin::Coin<sdye::SDYE>>(&scenario);
        let out = coin::split(&mut shares, 800, test_scenario::ctx(&mut scenario));
        let (plan, base_opt) = entrypoints::request_withdraw(&mut v, &mut q, out, &clock, test_scenario::ctx(&mut scenario));
        assert!(vault::queued_request_id(&plan) == 1, 0);
        option::destroy_none(base_opt);
        transfer::public_transfer(shares, user2);
        assert!(active_locked_shares(&q, 2) == 1_600, 0);
        assert_balance_invariant(&v);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    test_scenario::next_tx(&mut scenario, user3);
    {
        let clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);
        let mut shares = test_scenario::take_from_sender<coin::Coin<sdye::SDYE>>(&scenario);
        let out = coin::split(&mut shares, 800, test_scenario::ctx(&mut scenario));
        let (plan, base_opt) = entrypoints::request_withdraw(&mut v, &mut q, out, &clock, test_scenario::ctx(&mut scenario));
        assert!(vault::queued_request_id(&plan) == 2, 0);
        option::destroy_none(base_opt);
        transfer::public_transfer(shares, user3);
        assert!(active_locked_shares(&q, 3) == 2_400, 0);
        assert_balance_invariant(&v);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    test_scenario::next_tx(&mut scenario, user4);
    {
        let clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);
        let mut shares = test_scenario::take_from_sender<coin::Coin<sdye::SDYE>>(&scenario);
        let out = coin::split(&mut shares, 800, test_scenario::ctx(&mut scenario));
        let (plan, base_opt) = entrypoints::request_withdraw(&mut v, &mut q, out, &clock, test_scenario::ctx(&mut scenario));
        assert!(vault::queued_request_id(&plan) == 3, 0);
        option::destroy_none(base_opt);
        transfer::public_transfer(shares, user4);
        assert!(active_locked_shares(&q, 4) == 3_200, 0);
        assert_balance_invariant(&v);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    test_scenario::next_tx(&mut scenario, user5);
    {
        let clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);
        let mut shares = test_scenario::take_from_sender<coin::Coin<sdye::SDYE>>(&scenario);
        let out = coin::split(&mut shares, 800, test_scenario::ctx(&mut scenario));
        let (plan, base_opt) = entrypoints::request_withdraw(&mut v, &mut q, out, &clock, test_scenario::ctx(&mut scenario));
        assert!(vault::queued_request_id(&plan) == 4, 0);
        option::destroy_none(base_opt);
        transfer::public_transfer(shares, user5);
        assert!(queue::total_pending_shares(queue::state(&q)) == 4_000, 0);
        assert!(active_locked_shares(&q, 5) == 4_000, 0);
        assert!(entrypoints::total_shares(&v) == 5_000, 0);
        assert_balance_invariant(&v);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut clock = test_scenario::take_shared<clock::Clock>(&scenario);
        clock::set_for_testing(&mut clock, 10_000);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);
        let (moved, bounty_opt) = entrypoints::cycle(&mut v, &mut q, &cfg, 1_000_000_000, &clock, test_scenario::ctx(&mut scenario));
        assert!(moved == 5, 0);
        assert!(option::is_none(&bounty_opt), 0);
        option::destroy_none(bounty_opt);
        assert!(queue::total_ready_usdc(queue::state(&q)) == 4_000, 0);
        assert_balance_invariant(&v);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    // Claims preserve fairness: each user gets 800, remaining total shares = 1,000.
    test_scenario::next_tx(&mut scenario, user1);
    {
        let clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);
        let out = entrypoints::claim(&mut v, &mut q, 0, &clock, test_scenario::ctx(&mut scenario));
        assert!(coin::value(&out) == 800, 0);
        transfer::public_transfer(out, user1);
        assert_balance_invariant(&v);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };
    test_scenario::next_tx(&mut scenario, user2);
    {
        let clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);
        let out = entrypoints::claim(&mut v, &mut q, 1, &clock, test_scenario::ctx(&mut scenario));
        assert!(coin::value(&out) == 800, 0);
        transfer::public_transfer(out, user2);
        assert_balance_invariant(&v);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };
    test_scenario::next_tx(&mut scenario, user3);
    {
        let clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);
        let out = entrypoints::claim(&mut v, &mut q, 2, &clock, test_scenario::ctx(&mut scenario));
        assert!(coin::value(&out) == 800, 0);
        transfer::public_transfer(out, user3);
        assert_balance_invariant(&v);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };
    test_scenario::next_tx(&mut scenario, user4);
    {
        let clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);
        let out = entrypoints::claim(&mut v, &mut q, 3, &clock, test_scenario::ctx(&mut scenario));
        assert!(coin::value(&out) == 800, 0);
        transfer::public_transfer(out, user4);
        assert_balance_invariant(&v);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };
    test_scenario::next_tx(&mut scenario, user5);
    {
        let clock = test_scenario::take_shared<clock::Clock>(&scenario);
        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_shared<config::Config>(&scenario);
        let out = entrypoints::claim(&mut v, &mut q, 4, &clock, test_scenario::ctx(&mut scenario));
        assert!(coin::value(&out) == 800, 0);
        transfer::public_transfer(out, user5);
        assert!(entrypoints::total_shares(&v) == 1_000, 0);
        assert!(entrypoints::treasury_usdc(&v) == 0, 0);
        assert!(entrypoints::deployed_balance(&v) == 1_000, 0);
        assert_balance_invariant(&v);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
    };

    let _effects = test_scenario::end(scenario);
}
