module self_driving_yield::cetus_vault_storage_tests;

use cetus_clmm::config::{Self as clmm_config, AdminCap, GlobalConfig, new_global_config_for_test};
use cetus_clmm::pool::Pool;
use cetus_clmm::pool_tests;
use cetus_clmm::tick_math;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::test_scenario;

use self_driving_yield::cetus_live;
use self_driving_yield::config;
use self_driving_yield::entrypoints;
use self_driving_yield::errors;
use self_driving_yield::queue;
use self_driving_yield::sdye;
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
