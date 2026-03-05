module self_driving_yield::scenario_integration_tests;

use sui::clock;
use sui::coin;
use sui::test_scenario;

use self_driving_yield::config;
use self_driving_yield::sdye;
use self_driving_yield::entrypoints;
use self_driving_yield::usdc;
use self_driving_yield::queue;
use self_driving_yield::vault;

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

        let cfg = test_scenario::take_from_sender<config::Config>(&scenario);
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
        test_scenario::return_to_sender(&scenario, cfg);

        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
    };
    test_scenario::next_tx(&mut scenario, admin);

    // Tx3: cycle twice (multi-cycle), then claim.
    {
        let mut clock = test_scenario::take_shared<clock::Clock>(&scenario);
        clock::set_for_testing(&mut clock, 2000);

        let mut v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let cfg = test_scenario::take_from_sender<config::Config>(&scenario);

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

        test_scenario::return_to_sender(&scenario, cfg);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
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

        let cfg = test_scenario::take_from_sender<config::Config>(&scenario);

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
        test_scenario::return_to_sender(&scenario, cfg);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
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
        let cfg = test_scenario::take_from_sender<config::Config>(&scenario);

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

        test_scenario::return_to_sender(&scenario, cfg);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
    };

    let _effects = test_scenario::end(scenario);
}
