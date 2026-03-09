module self_driving_yield::cetus_vault_storage_tests;

use cetus_clmm::config::{Self as clmm_config, AdminCap, GlobalConfig, new_global_config_for_test};
use cetus_clmm::pool::Pool;
use cetus_clmm::pool_tests;
use cetus_clmm::position;
use cetus_clmm::tick_math;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::test_scenario;

use self_driving_yield::cetus_live;
use self_driving_yield::config;
use self_driving_yield::entrypoints;
use self_driving_yield::errors;
use self_driving_yield::oracle;
use self_driving_yield::queue;
use self_driving_yield::sdye;
use self_driving_yield::types;
use self_driving_yield::usdc;

fun init_clmm(ctx: &mut TxContext): (Clock, AdminCap, GlobalConfig) {
    let clock = clock::create_for_testing(ctx);
    let (cap, mut cfg) = new_global_config_for_test(ctx, 2000);
    clmm_config::add_role(&cap, &mut cfg, @0x0, 0);
    (clock, cap, cfg)
}

#[allow(lint(uncallable_function), lint(share_owned))]
fun cleanup_clmm<CoinTypeA, CoinTypeB>(
    pool: Pool<CoinTypeA, CoinTypeB>,
    cap: AdminCap,
    cfg: GlobalConfig,
    clock: Clock,
) {
    transfer::public_share_object(pool);
    transfer::public_transfer(cap, @0x1);
    transfer::public_share_object(cfg);
    clock::destroy_for_testing(clock);
}

#[test]
fun vault_can_store_and_release_cetus_position() {
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
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
            100,
            tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
            2000,
            0,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));

        let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, test_scenario::ctx(&mut scenario));
        let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        let (change_a, change_b) = cetus_live::open_position_into_vault<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in,
            coin_b_in,
            4294966296,
            1000,
            10_000,
            true,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        assert!(entrypoints::has_stored_cetus_position(&v), 0);
        let stored_position_id = entrypoints::stored_cetus_position_id(&v);
        assert!(stored_position_id != @0x0, 0);
        assert!(entrypoints::live_cetus_enabled(&v), 0);
        assert!(entrypoints::live_cetus_position_present(&v), 0);
        assert!(entrypoints::live_cetus_last_position_id(&v) == stored_position_id, 0);
        assert!(entrypoints::live_cetus_last_principal_a(&v) > 0 || entrypoints::live_cetus_last_principal_b(&v) > 0, 0);
        assert!(entrypoints::live_cetus_last_snapshot_ts_ms(&v) == clock::timestamp_ms(&clock), 0);
        assert!(entrypoints::live_cetus_last_action_code(&v) == 1, 0);

        let (_, bounty_opt, live_amount_a, live_amount_b) = cetus_live::rebalance_live<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &mut q,
            &cfg,
            &pool,
            100_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        option::destroy_none(bounty_opt);
        assert!(entrypoints::has_stored_cetus_position(&v), 0);
        assert!(entrypoints::cetus_pool_id(&v) == object::id_to_address(&pool_id), 0);
        assert!(live_amount_a > 0 || live_amount_b > 0, 0);
        assert!(entrypoints::live_cetus_position_present(&v), 0);
        assert!(entrypoints::live_cetus_last_position_id(&v) == stored_position_id, 0);
        assert!(entrypoints::live_cetus_last_action_code(&v) == 2, 0);
        assert!(entrypoints::live_cetus_last_principal_a(&v) == live_amount_a, 0);
        assert!(entrypoints::live_cetus_last_principal_b(&v) == live_amount_b, 0);

        let (out_a, out_b) = cetus_live::close_stored_position_from_vault<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &cfg,
            &clmm_cfg,
            &mut pool,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(!entrypoints::has_stored_cetus_position(&v), 0);
        assert!(!entrypoints::live_cetus_position_present(&v), 0);
        assert!(entrypoints::live_cetus_last_position_id(&v) == stored_position_id, 0);
        assert!(entrypoints::live_cetus_last_principal_a(&v) == 0, 0);
        assert!(entrypoints::live_cetus_last_principal_b(&v) == 0, 0);
        assert!(entrypoints::live_cetus_last_action_code(&v) == 3, 0);
        assert!(coin::value(&out_a) > 0 || coin::value(&out_b) > 0, 0);

        transfer::public_transfer(change_a, admin);
        transfer::public_transfer(change_b, admin);
        transfer::public_transfer(out_a, admin);
        transfer::public_transfer(out_b, admin);

        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };

    test_scenario::end(scenario);
}

#[test]
fun vault_entry_wrappers_store_and_close_position() {
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
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
            100,
            tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
            2000,
            0,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));

        let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, test_scenario::ctx(&mut scenario));
        let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        cetus_live::open_position_into_vault_entry<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in,
            coin_b_in,
            4294966296,
            1000,
            10_000,
            true,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(entrypoints::has_stored_cetus_position(&v), 0);
        assert!(entrypoints::live_cetus_enabled(&v), 0);
        assert!(entrypoints::live_cetus_position_present(&v), 0);
        assert!(entrypoints::live_cetus_last_position_id(&v) == entrypoints::stored_cetus_position_id(&v), 0);
        assert!(entrypoints::live_cetus_last_action_code(&v) == 1, 0);

        let (_, bounty_opt, _, _) = cetus_live::rebalance_live<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &mut q,
            &cfg,
            &pool,
            100_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        option::destroy_none(bounty_opt);
        assert!(entrypoints::live_cetus_last_action_code(&v) == 2, 0);

        cetus_live::close_stored_position_from_vault_entry<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &cfg,
            &clmm_cfg,
            &mut pool,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(!entrypoints::has_stored_cetus_position(&v), 0);
        assert!(!entrypoints::live_cetus_position_present(&v), 0);
        assert!(entrypoints::live_cetus_last_action_code(&v) == 3, 0);

        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };

    test_scenario::next_tx(&mut scenario, admin);
    {
        let change_a = test_scenario::take_from_sender<coin::Coin<pool_tests::CoinA>>(&scenario);
        let change_b = test_scenario::take_from_sender<coin::Coin<pool_tests::CoinB>>(&scenario);
        let out_a = test_scenario::take_from_sender<coin::Coin<pool_tests::CoinA>>(&scenario);
        let out_b = test_scenario::take_from_sender<coin::Coin<pool_tests::CoinB>>(&scenario);
        assert!(coin::value(&change_a) + coin::value(&out_a) > 0, 0);
        assert!(coin::value(&change_b) + coin::value(&out_b) > 0, 0);
        transfer::public_transfer(change_a, admin);
        transfer::public_transfer(change_b, admin);
        transfer::public_transfer(out_a, admin);
        transfer::public_transfer(out_b, admin);
    };

    test_scenario::end(scenario);
}

#[test]
fun rebalance_live_without_stored_position_returns_zero_snapshot() {
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
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
            100,
            tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
            2000,
            0,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));
        let (_, bounty_opt, live_amount_a, live_amount_b) = cetus_live::rebalance_live<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &mut q,
            &cfg,
            &pool,
            100_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        option::destroy_none(bounty_opt);
        assert!(live_amount_a == 0, 0);
        assert!(live_amount_b == 0, 0);
        assert!(!entrypoints::live_cetus_position_present(&v), 0);

        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };

    test_scenario::end(scenario);
}

#[test]
fun cycle_live_closes_stored_position_under_queue_pressure() {
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
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
            100,
            tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
            2000,
            0,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let mut shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));

        let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, test_scenario::ctx(&mut scenario));
        let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        let (change_a, change_b) = cetus_live::open_position_into_vault<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in,
            coin_b_in,
            4294966296,
            1000,
            10_000,
            true,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        transfer::public_transfer(change_a, admin);
        transfer::public_transfer(change_b, admin);
        assert!(entrypoints::has_stored_cetus_position(&v), 0);

        entrypoints::deploy_for_testing(&mut v, 9_000);
        let withdraw_shares = coin::split(&mut shares, 9_000, test_scenario::ctx(&mut scenario));
        let (_, base_opt) = entrypoints::request_withdraw(&mut v, &mut q, withdraw_shares, &clock, test_scenario::ctx(&mut scenario));
        option::destroy_none(base_opt);
        transfer::public_transfer(shares, admin);

        let (_, bounty_opt, out_a, out_b, action_code, amount_a, amount_b) = cetus_live::cycle_live<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &mut q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            1_000_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        option::destroy_none(bounty_opt);
        assert!(action_code == self_driving_yield::types::lp_action_close(), 0);
        assert!(!entrypoints::has_stored_cetus_position(&v), 0);
        assert!(!entrypoints::live_cetus_position_present(&v), 0);
        assert!(amount_a > 0 || amount_b > 0, 0);
        assert!(coin::value(&out_a) > 0 || coin::value(&out_b) > 0, 0);
        transfer::public_transfer(out_a, admin);
        transfer::public_transfer(out_b, admin);

        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };

    test_scenario::end(scenario);
}

#[test]
fun cycle_live_keeps_position_when_queue_is_healthy() {
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
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
            100,
            tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
            2000,
            0,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, admin);

        let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, test_scenario::ctx(&mut scenario));
        let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        let (change_a, change_b) = cetus_live::open_position_into_vault<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in,
            coin_b_in,
            4294966296,
            1000,
            10_000,
            true,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        transfer::public_transfer(change_a, admin);
        transfer::public_transfer(change_b, admin);

        let stored_before = entrypoints::stored_cetus_position_id(&v);
        let (_, bounty_opt, out_a, out_b, action_code, amount_a, amount_b) = cetus_live::cycle_live<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &mut q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            1_000_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        let bounty = option::destroy_some(bounty_opt);
        transfer::public_transfer(bounty, admin);
        assert!(action_code == self_driving_yield::types::lp_action_hold(), 0);
        assert!(entrypoints::has_stored_cetus_position(&v), 0);
        assert!(entrypoints::stored_cetus_position_id(&v) == stored_before, 0);
        assert!(amount_a > 0 || amount_b > 0, 0);
        assert!(coin::value(&out_a) == 0, 0);
        assert!(coin::value(&out_b) == 0, 0);
        coin::destroy_zero(out_a);
        coin::destroy_zero(out_b);

        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };

    test_scenario::end(scenario);
}

#[test]
fun cycle_live_entry_closes_and_transfers_assets() {
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
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
            100,
            tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
            2000,
            0,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let mut shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));

        let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, test_scenario::ctx(&mut scenario));
        let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        cetus_live::open_position_into_vault_entry<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in,
            coin_b_in,
            4294966296,
            1000,
            10_000,
            true,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        entrypoints::deploy_for_testing(&mut v, 9_000);
        let withdraw_shares = coin::split(&mut shares, 9_000, test_scenario::ctx(&mut scenario));
        let (_, base_opt) = entrypoints::request_withdraw(&mut v, &mut q, withdraw_shares, &clock, test_scenario::ctx(&mut scenario));
        option::destroy_none(base_opt);
        transfer::public_transfer(shares, admin);

        cetus_live::cycle_live_entry<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &mut q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            1_000_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(!entrypoints::has_stored_cetus_position(&v), 0);

        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };
    test_scenario::next_tx(&mut scenario, admin);

    {
        let out_a = test_scenario::take_from_sender<coin::Coin<pool_tests::CoinA>>(&scenario);
        let out_b = test_scenario::take_from_sender<coin::Coin<pool_tests::CoinB>>(&scenario);
        assert!(coin::value(&out_a) > 0 || coin::value(&out_b) > 0, 0);
        transfer::public_transfer(out_a, admin);
        transfer::public_transfer(out_b, admin);
    };

    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = errors::E_MISSING_OBJECT, location = self_driving_yield::entrypoints)]
fun stored_position_id_aborts_when_missing() {
    let admin = @0x1;
    let mut scenario = test_scenario::begin(admin);
    test_scenario::create_system_objects(&mut scenario);

    {
        let sdye_treasury = coin::create_treasury_cap_for_testing<sdye::SDYE>(test_scenario::ctx(&mut scenario));
        entrypoints::bootstrap<usdc::USDC>(sdye_treasury, 0, 0, test_scenario::ctx(&mut scenario));
    };
    test_scenario::next_tx(&mut scenario, admin);

    {
        let v = test_scenario::take_shared<entrypoints::Vault<usdc::USDC>>(&scenario);
        let _ = entrypoints::stored_cetus_position_id(&v);
        test_scenario::return_shared(v);
    };

    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = errors::E_INVALID_PLAN, location = self_driving_yield::entrypoints)]
fun storing_duplicate_position_aborts() {
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

        let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
            100,
            tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
            2000,
            0,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));

        let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, test_scenario::ctx(&mut scenario));
        let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        let (change_a, change_b) = cetus_live::open_position_into_vault<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in,
            coin_b_in,
            4294966296,
            1000,
            10_000,
            true,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        transfer::public_transfer(change_a, admin);
        transfer::public_transfer(change_b, admin);
        assert!(entrypoints::has_stored_cetus_position(&v), 0);

        let coin_a_in_2 = coin::mint_for_testing<pool_tests::CoinA>(100_000, test_scenario::ctx(&mut scenario));
        let coin_b_in_2 = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        let (change_a_2, change_b_2) = cetus_live::open_position_into_vault<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in_2,
            coin_b_in_2,
            4294966296,
            1000,
            10_000,
            true,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        transfer::public_transfer(change_a_2, admin);
        transfer::public_transfer(change_b_2, admin);

        test_scenario::return_shared(v);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };

    test_scenario::end(scenario);
}

#[test]
fun strategy_plan_reports_open_add_remove_and_close_paths() {
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
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
            100,
            tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
            2000,
            0,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let mut shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));

        let (lp_action_open, lp_reason_open, current_lp_open, target_lp_open, _, _) = entrypoints::strategy_plan_lp_for_testing(&v, &q, &cfg);
        assert!(lp_action_open == types::lp_action_open(), 0);
        assert!(lp_reason_open == types::strategy_reason_target_expand(), 0);
        assert!(current_lp_open == 0, 0);
        assert!(target_lp_open > 0, 0);
        assert!(!entrypoints::has_stored_cetus_position(&v), 0);
        cetus_live::assert_planned_open_action(&v, &q, &cfg);

        let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, test_scenario::ctx(&mut scenario));
        let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        let (change_a, change_b) = cetus_live::execute_planned_open_into_vault<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in,
            coin_b_in,
            4294966296,
            1000,
            10_000,
            true,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        transfer::public_transfer(change_a, admin);
        transfer::public_transfer(change_b, admin);
        assert!(entrypoints::live_cetus_last_action_code(&v) == entrypoints::live_cetus_action_open(), 0);

        entrypoints::deploy_for_testing(&mut v, 1_000);
        let (lp_action_add, lp_reason_add, current_lp_add, target_lp_add, _, _) = entrypoints::strategy_plan_lp_for_testing(&v, &q, &cfg);
        assert!(lp_action_add == types::lp_action_add(), 0);
        assert!(lp_reason_add == types::strategy_reason_target_expand(), 0);
        assert!(current_lp_add < target_lp_add, 0);
        assert!(entrypoints::has_stored_cetus_position(&v), 0);
        cetus_live::assert_planned_add_action(&v, &q, &cfg);

        let coin_a_in_add = coin::mint_for_testing<pool_tests::CoinA>(100_000, test_scenario::ctx(&mut scenario));
        let coin_b_in_add = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        let (change_a_add, change_b_add) = cetus_live::execute_planned_add_to_vault<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in_add,
            coin_b_in_add,
            10_000,
            true,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        transfer::public_transfer(change_a_add, admin);
        transfer::public_transfer(change_b_add, admin);
        assert!(entrypoints::live_cetus_last_action_code(&v) == entrypoints::live_cetus_action_add(), 0);

        entrypoints::deploy_for_testing(&mut v, 4_000);
        let (lp_action_remove, lp_reason_remove, current_lp_remove, target_lp_remove, _, _) = entrypoints::strategy_plan_lp_for_testing(&v, &q, &cfg);
        assert!(lp_action_remove == types::lp_action_remove(), 0);
        assert!(lp_reason_remove == types::strategy_reason_target_shrink(), 0);
        assert!(current_lp_remove > target_lp_remove, 0);
        cetus_live::assert_planned_remove_action(&v, &q, &cfg);

        let liq_before = position::liquidity(entrypoints::borrow_stored_cetus_position(&v));
        let delta = liq_before / 2;
        let (out_a_partial, out_b_partial) = cetus_live::execute_planned_remove_from_vault<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            delta,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(entrypoints::live_cetus_last_action_code(&v) == entrypoints::live_cetus_action_remove(), 0);
        transfer::public_transfer(out_a_partial, admin);
        transfer::public_transfer(out_b_partial, admin);

        entrypoints::deploy_for_testing(&mut v, 4_000);
        let withdraw_shares = coin::split(&mut shares, 9_000, test_scenario::ctx(&mut scenario));
        let (_, base_opt) = entrypoints::request_withdraw(&mut v, &mut q, withdraw_shares, &clock, test_scenario::ctx(&mut scenario));
        option::destroy_none(base_opt);
        transfer::public_transfer(shares, admin);

        let (lp_action_close, lp_reason_close, _, _, _, _) = entrypoints::strategy_plan_lp_for_testing(&v, &q, &cfg);
        assert!(lp_action_close == types::lp_action_close(), 0);
        assert!(lp_reason_close == types::strategy_reason_queue_pressure(), 0);
        cetus_live::assert_planned_close_action(&v, &q, &cfg);

        let (out_a, out_b) = cetus_live::execute_planned_close_from_vault<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(!entrypoints::has_stored_cetus_position(&v), 0);
        assert!(entrypoints::live_cetus_last_action_code(&v) == entrypoints::live_cetus_action_close(), 0);
        transfer::public_transfer(out_a, admin);
        transfer::public_transfer(out_b, admin);

        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };

    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = errors::E_INVALID_PLAN, location = self_driving_yield::cetus_live)]
fun execute_planned_add_aborts_when_plan_is_not_add() {
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
        let q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
            100,
            tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
            2000,
            0,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, admin);

        let (lp_action, _, _, _, _, _) = entrypoints::strategy_plan_lp_for_testing(&v, &q, &cfg);
        assert!(lp_action == types::lp_action_open(), 0);

        let coin_a_in_add = coin::mint_for_testing<pool_tests::CoinA>(100, test_scenario::ctx(&mut scenario));
        let coin_b_in_add = coin::mint_for_testing<pool_tests::CoinB>(100, test_scenario::ctx(&mut scenario));
        let (_change_a_add, _change_b_add) = cetus_live::execute_planned_add_to_vault<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in_add,
            coin_b_in_add,
            10_000,
            true,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        transfer::public_transfer(_change_a_add, admin);
        transfer::public_transfer(_change_b_add, admin);

        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };

    test_scenario::end(scenario);
}

#[test]
fun cycle_managed_live_lp_entry_opens_position_when_missing() {
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
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
            100,
            tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
            2000,
            0,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, admin);

        assert!(!entrypoints::has_stored_cetus_position(&v), 0);

        // Mint exact fixed-side amount to cover the "change==0" branch in the wrapper.
        let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(10_000, test_scenario::ctx(&mut scenario));
        let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        cetus_live::cycle_managed_live_lp_entry<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &mut q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in,
            coin_b_in,
            4294966296,
            1000,
            10_000,
            true,
            0,
            1_000_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        assert!(entrypoints::has_stored_cetus_position(&v), 0);
        assert!(entrypoints::live_cetus_last_action_code(&v) == entrypoints::live_cetus_action_open(), 0);

        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };

    test_scenario::end(scenario);
}

#[test]
fun cycle_managed_live_lp_entry_open_transfers_non_zero_change_coins() {
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
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
            100,
            tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
            2000,
            0,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, admin);

        // Large input coins => non-zero change coins => wrapper should transfer them (not destroy).
        let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, test_scenario::ctx(&mut scenario));
        let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        cetus_live::cycle_managed_live_lp_entry<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &mut q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in,
            coin_b_in,
            4294966296,
            1000,
            10_000,
            true,
            0,
            1_000_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(entrypoints::has_stored_cetus_position(&v), 0);

        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };
    test_scenario::next_tx(&mut scenario, admin);

    {
        // Verify that at least one change coin was transferred back to the sender.
        let out_a = test_scenario::take_from_sender<coin::Coin<pool_tests::CoinA>>(&scenario);
        assert!(coin::value(&out_a) > 0, 0);
        transfer::public_transfer(out_a, admin);
    };

    test_scenario::end(scenario);
}

#[test]
fun cycle_managed_live_lp_entry_adds_liquidity_when_planned_add() {
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
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
            100,
            tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
            2000,
            0,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, admin);

        // Create a stored position, but keep cetus_balance at 0 so the planner expects ADD.
        let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, test_scenario::ctx(&mut scenario));
        let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        cetus_live::open_position_into_vault_entry<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in,
            coin_b_in,
            4294966296,
            1000,
            10_000,
            true,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(entrypoints::has_stored_cetus_position(&v), 0);

        // Mint exact fixed-side amount to cover the "change==0" branch in the wrapper.
        let coin_a_in_add = coin::mint_for_testing<pool_tests::CoinA>(10_000, test_scenario::ctx(&mut scenario));
        let coin_b_in_add = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        cetus_live::cycle_managed_live_lp_entry<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &mut q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in_add,
            coin_b_in_add,
            0,
            0,
            10_000,
            true,
            0,
            1_000_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(entrypoints::has_stored_cetus_position(&v), 0);
        assert!(entrypoints::live_cetus_last_action_code(&v) == entrypoints::live_cetus_action_add(), 0);

        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };

    test_scenario::end(scenario);
}

#[test]
fun cycle_managed_live_lp_entry_removes_liquidity_when_planned_remove() {
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
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
            100,
            tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
            2000,
            0,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, admin);

        let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, test_scenario::ctx(&mut scenario));
        let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        cetus_live::open_position_into_vault_entry<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in,
            coin_b_in,
            4294966296,
            1000,
            10_000,
            true,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(entrypoints::has_stored_cetus_position(&v), 0);

        // Make current_lp > target_lp to force planner REMOVE.
        entrypoints::deploy_for_testing(&mut v, 9_000);
        let liq_before = position::liquidity(entrypoints::borrow_stored_cetus_position(&v));
        let delta = if (liq_before > 1) { liq_before / 2 } else { liq_before };
        assert!(delta > 0, 0);

        let coin_a_in_unused = coin::mint_for_testing<pool_tests::CoinA>(1, test_scenario::ctx(&mut scenario));
        let coin_b_in_unused = coin::mint_for_testing<pool_tests::CoinB>(1, test_scenario::ctx(&mut scenario));
        cetus_live::cycle_managed_live_lp_entry<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &mut q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in_unused,
            coin_b_in_unused,
            0,
            0,
            0,
            true,
            delta,
            1_000_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(entrypoints::has_stored_cetus_position(&v), 0);
        assert!(entrypoints::live_cetus_last_action_code(&v) == entrypoints::live_cetus_action_remove(), 0);

        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };

    test_scenario::end(scenario);
}

#[test]
fun cycle_managed_live_lp_entry_closes_before_cycle_under_queue_pressure() {
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
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
            100,
            tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
            2000,
            0,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let mut shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));

        let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, test_scenario::ctx(&mut scenario));
        let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        cetus_live::open_position_into_vault_entry<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in,
            coin_b_in,
            4294966296,
            1000,
            10_000,
            true,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(entrypoints::has_stored_cetus_position(&v), 0);

        entrypoints::deploy_for_testing(&mut v, 9_000);
        let withdraw_shares = coin::split(&mut shares, 9_000, test_scenario::ctx(&mut scenario));
        let (_, base_opt) = entrypoints::request_withdraw(&mut v, &mut q, withdraw_shares, &clock, test_scenario::ctx(&mut scenario));
        option::destroy_none(base_opt);
        transfer::public_transfer(shares, admin);

        let coin_a_in_unused = coin::mint_for_testing<pool_tests::CoinA>(1, test_scenario::ctx(&mut scenario));
        let coin_b_in_unused = coin::mint_for_testing<pool_tests::CoinB>(1, test_scenario::ctx(&mut scenario));
        cetus_live::cycle_managed_live_lp_entry<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &mut q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in_unused,
            coin_b_in_unused,
            0,
            0,
            0,
            true,
            0,
            1_000_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(!entrypoints::has_stored_cetus_position(&v), 0);
        assert!(entrypoints::live_cetus_last_action_code(&v) == entrypoints::live_cetus_action_close(), 0);

        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };

    test_scenario::end(scenario);
}

#[test]
fun cycle_managed_live_lp_entry_holds_and_snapshots_when_on_target() {
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
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
            100,
            tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
            2000,
            0,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));

        // Small total_assets => max_bounty=floor(total_assets*5/10000)=0; target stays stable across cycle().
        let usdc_in = coin::mint_for_testing<usdc::USDC>(1_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, admin);

        let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, test_scenario::ctx(&mut scenario));
        let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        cetus_live::open_position_into_vault_entry<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in,
            coin_b_in,
            4294966296,
            1000,
            10_000,
            true,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(entrypoints::has_stored_cetus_position(&v), 0);

        let (_, _, _, target_lp, _, _) = entrypoints::strategy_plan_lp_for_testing(&v, &q, &cfg);
        assert!(target_lp > 0, 0);
        entrypoints::deploy_for_testing(&mut v, target_lp);

        let coin_a_in_unused = coin::mint_for_testing<pool_tests::CoinA>(1, test_scenario::ctx(&mut scenario));
        let coin_b_in_unused = coin::mint_for_testing<pool_tests::CoinB>(1, test_scenario::ctx(&mut scenario));
        cetus_live::cycle_managed_live_lp_entry<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &mut q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in_unused,
            coin_b_in_unused,
            0,
            0,
            0,
            true,
            0,
            1_000_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(entrypoints::has_stored_cetus_position(&v), 0);
        assert!(entrypoints::live_cetus_last_action_code(&v) == entrypoints::live_cetus_action_hold(), 0);

        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };

    test_scenario::end(scenario);
}

#[test]
fun cycle_managed_live_lp_entry_closes_after_cycle_when_cycle_enters_only_unwind() {
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
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        let (mut clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
            100,
            tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
            2000,
            0,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, admin);

        // Stored position is required to test the close-after-cycle branch.
        let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, test_scenario::ctx(&mut scenario));
        let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        cetus_live::open_position_into_vault_entry<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in,
            coin_b_in,
            4294966296,
            1000,
            10_000,
            true,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(entrypoints::has_stored_cetus_position(&v), 0);

        // Pre-fill oracle snapshots up to (but not including) MIN_SAMPLES. Regime remains Normal.
        let p = oracle::price_precision();
        let hi = p + 30_000_000;
        let lo = p - 30_000_000;
        let mut ts: u64 = 0;
        let mut i: u64 = 0;
        while (i < 11) {
            ts = ts + 1000;
            clock::set_for_testing(&mut clock, ts);
            let price = if (i % 2 == 0) { hi } else { lo };
            let (_, bounty_opt) = entrypoints::cycle(&mut v, &mut q, &cfg, price, &clock, test_scenario::ctx(&mut scenario));
            if (option::is_some(&bounty_opt)) {
                let bounty = option::destroy_some(bounty_opt);
                transfer::public_transfer(bounty, admin);
            } else {
                option::destroy_none(bounty_opt);
            };
            i = i + 1;
        };
        assert!(!entrypoints::is_only_unwind_mode(&v), 0);
        assert!(entrypoints::has_stored_cetus_position(&v), 0);

        // 12th snapshot happens inside the wrapper cycle() and can enter Storm => OnlyUnwind.
        ts = ts + 1000;
        clock::set_for_testing(&mut clock, ts);
        let coin_a_zero = coin::zero<pool_tests::CoinA>(test_scenario::ctx(&mut scenario));
        let coin_b_zero = coin::zero<pool_tests::CoinB>(test_scenario::ctx(&mut scenario));
        cetus_live::cycle_managed_live_lp_entry<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &mut q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_zero,
            coin_b_zero,
            0,
            0,
            0,
            true,
            0,
            hi,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(!entrypoints::has_stored_cetus_position(&v), 0);
        assert!(entrypoints::live_cetus_last_action_code(&v) == entrypoints::live_cetus_action_close(), 0);
        assert!(entrypoints::is_only_unwind_mode(&v), 0);

        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };

    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = errors::E_INVALID_PLAN, location = self_driving_yield::cetus_live)]
fun execute_planned_open_aborts_when_plan_is_not_open() {
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
        let q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
            100,
            tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
            2000,
            0,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, admin);

        let (lp_action_open, _, _, _, _, _) = entrypoints::strategy_plan_lp_for_testing(&v, &q, &cfg);
        assert!(lp_action_open == types::lp_action_open(), 0);

        let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, test_scenario::ctx(&mut scenario));
        let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        let (change_a, change_b) = cetus_live::execute_planned_open_into_vault<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in,
            coin_b_in,
            4294966296,
            1000,
            10_000,
            true,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        transfer::public_transfer(change_a, admin);
        transfer::public_transfer(change_b, admin);

        entrypoints::deploy_for_testing(&mut v, 1_000);
        let (lp_action_add, _, _, _, _, _) = entrypoints::strategy_plan_lp_for_testing(&v, &q, &cfg);
        assert!(lp_action_add == types::lp_action_add(), 0);

        let coin_a_in_again = coin::mint_for_testing<pool_tests::CoinA>(100, test_scenario::ctx(&mut scenario));
        let coin_b_in_again = coin::mint_for_testing<pool_tests::CoinB>(100, test_scenario::ctx(&mut scenario));
        let (_change_a_again, _change_b_again) = cetus_live::execute_planned_open_into_vault<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in_again,
            coin_b_in_again,
            4294966296,
            1000,
            10_000,
            true,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        transfer::public_transfer(_change_a_again, admin);
        transfer::public_transfer(_change_b_again, admin);

        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };

    test_scenario::end(scenario);
}

#[test]
fun planned_entry_wrappers_cover_open_add_remove_and_close() {
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
        let mut q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
            100,
            tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
            2000,
            0,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));

        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let mut shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));

        cetus_live::assert_planned_open_action(&v, &q, &cfg);
        let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, test_scenario::ctx(&mut scenario));
        let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        cetus_live::execute_planned_open_into_vault_entry<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in,
            coin_b_in,
            4294966296,
            1000,
            10_000,
            true,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(entrypoints::live_cetus_last_action_code(&v) == entrypoints::live_cetus_action_open(), 0);

        entrypoints::deploy_for_testing(&mut v, 1_000);
        cetus_live::assert_planned_add_action(&v, &q, &cfg);
        let coin_a_in_add = coin::mint_for_testing<pool_tests::CoinA>(100_000, test_scenario::ctx(&mut scenario));
        let coin_b_in_add = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        cetus_live::execute_planned_add_to_vault_entry<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            coin_a_in_add,
            coin_b_in_add,
            10_000,
            true,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(entrypoints::live_cetus_last_action_code(&v) == entrypoints::live_cetus_action_add(), 0);

        entrypoints::deploy_for_testing(&mut v, 4_000);
        cetus_live::assert_planned_remove_action(&v, &q, &cfg);
        let liq_before = position::liquidity(entrypoints::borrow_stored_cetus_position(&v));
        cetus_live::execute_planned_remove_from_vault_entry<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            liq_before / 2,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(entrypoints::live_cetus_last_action_code(&v) == entrypoints::live_cetus_action_remove(), 0);

        entrypoints::deploy_for_testing(&mut v, 4_000);
        let withdraw_shares = coin::split(&mut shares, 9_000, test_scenario::ctx(&mut scenario));
        let (_, base_opt) = entrypoints::request_withdraw(&mut v, &mut q, withdraw_shares, &clock, test_scenario::ctx(&mut scenario));
        option::destroy_none(base_opt);
        transfer::public_transfer(shares, admin);
        cetus_live::assert_planned_close_action(&v, &q, &cfg);
        cetus_live::execute_planned_close_from_vault_entry<usdc::USDC, pool_tests::CoinA, pool_tests::CoinB>(
            &mut v,
            &q,
            &cfg,
            &clmm_cfg,
            &mut pool,
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        assert!(!entrypoints::has_stored_cetus_position(&v), 0);
        assert!(entrypoints::live_cetus_last_action_code(&v) == entrypoints::live_cetus_action_close(), 0);

        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };

    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = errors::E_INVALID_PLAN, location = self_driving_yield::cetus_live)]
fun assert_planned_open_aborts_when_plan_is_not_open() {
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
        let q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(100, tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)), 2000, 0, &clock, test_scenario::ctx(&mut scenario));
        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));
        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, admin);
        let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, test_scenario::ctx(&mut scenario));
        let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, test_scenario::ctx(&mut scenario));
        let (change_a, change_b) = cetus_live::open_position_into_vault(&mut v, &cfg, &clmm_cfg, &mut pool, coin_a_in, coin_b_in, 4294966296, 1000, 10_000, true, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(change_a, admin);
        transfer::public_transfer(change_b, admin);
        cetus_live::assert_planned_open_action(&v, &q, &cfg);

        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };

    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = errors::E_INVALID_PLAN, location = self_driving_yield::cetus_live)]
fun assert_planned_remove_aborts_when_plan_is_not_remove() {
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
        let q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(100, tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)), 2000, 0, &clock, test_scenario::ctx(&mut scenario));
        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));
        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, admin);
        cetus_live::assert_planned_remove_action(&v, &q, &cfg);

        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };

    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = errors::E_INVALID_PLAN, location = self_driving_yield::cetus_live)]
fun assert_planned_close_aborts_when_plan_is_not_close() {
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
        let q = test_scenario::take_shared<queue::WithdrawalQueue>(&scenario);
        let mut cfg = test_scenario::take_shared<config::Config>(&scenario);
        let cap = test_scenario::take_from_sender<config::AdminCap>(&scenario);

        let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(test_scenario::ctx(&mut scenario));
        let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(100, tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)), 2000, 0, &clock, test_scenario::ctx(&mut scenario));
        let pool_id = object::id(&pool);
        config::set_cetus_pool_id(&mut cfg, &cap, object::id_to_address(&pool_id));
        let usdc_in = coin::mint_for_testing<usdc::USDC>(10_000, test_scenario::ctx(&mut scenario));
        let shares = entrypoints::deposit(&mut v, usdc_in, &clock, test_scenario::ctx(&mut scenario));
        transfer::public_transfer(shares, admin);
        cetus_live::assert_planned_close_action(&v, &q, &cfg);

        test_scenario::return_shared(v);
        test_scenario::return_shared(q);
        test_scenario::return_shared(cfg);
        test_scenario::return_to_sender(&scenario, cap);
        cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
    };

    test_scenario::end(scenario);
}
