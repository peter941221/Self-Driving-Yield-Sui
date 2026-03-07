module self_driving_yield::cetus_live_tests;

use cetus_clmm::config::{Self, AdminCap, GlobalConfig, new_global_config_for_test};
use cetus_clmm::pool::Pool;
use cetus_clmm::pool_tests;
use cetus_clmm::position;
use cetus_clmm::tick_math;
use integer_mate::i32;
use sui::clock::{Self, Clock};
use sui::coin;

use self_driving_yield::cetus_amm;
use self_driving_yield::cetus_live;
use self_driving_yield::config as vault_config;
use self_driving_yield::errors;

fun init_clmm(ctx: &mut TxContext): (Clock, AdminCap, GlobalConfig) {
    let clock = clock::create_for_testing(ctx);
    let (cap, mut cfg) = new_global_config_for_test(ctx, 2000);
    config::add_role(&cap, &mut cfg, @0x0, 0);
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
fun open_and_close_live_helpers_work() {
    let ctx = &mut tx_context::dummy();
    let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(ctx);

    let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
        100,
        tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
        2000,
        0,
        &clock,
        ctx,
    );

    let (mut cfg, admin_cap) = vault_config::new(0, 0, ctx);
    let pool_id = object::id(&pool);
    vault_config::set_cetus_pool_id(&mut cfg, &admin_cap, object::id_to_address(&pool_id));

    let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, ctx);
    let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, ctx);
    let (position_nft, change_a, change_b) = cetus_live::open_position_with_liquidity(
        &cfg,
        &clmm_cfg,
        &mut pool,
        coin_a_in,
        coin_b_in,
        i32::as_u32(pool_tests::nt(1_000)),
        i32::as_u32(pool_tests::pt(1_000)),
        10_000,
        true,
        &clock,
        ctx,
    );

    assert!(position::liquidity(&position_nft) > 0, 0);
    assert!(coin::value(&change_a) < 100_000, 0);
    assert!(coin::value(&change_b) <= 100_000, 0);

    let (coin_a_out, coin_b_out) = cetus_live::close_position_and_withdraw(
        &cfg,
        &clmm_cfg,
        &mut pool,
        position_nft,
        &clock,
        ctx,
    );
    assert!(coin::value(&coin_a_out) > 0 || coin::value(&coin_b_out) > 0, 0);

    transfer::public_transfer(change_a, @0x1);
    transfer::public_transfer(change_b, @0x1);
    transfer::public_transfer(coin_a_out, @0x1);
    transfer::public_transfer(coin_b_out, @0x1);
    transfer::public_transfer(cfg, @0x1);
    transfer::public_transfer(admin_cap, @0x1);
    cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
}

#[test, expected_failure(abort_code = errors::E_OBJECT_MISMATCH, location = self_driving_yield::cetus_live)]
fun open_aborts_when_pool_mismatches_config() {
    let ctx = &mut tx_context::dummy();
    let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(ctx);

    let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
        100,
        tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
        2000,
        0,
        &clock,
        ctx,
    );

    let (mut cfg, admin_cap) = vault_config::new(0, 0, ctx);
    vault_config::set_cetus_pool_id(&mut cfg, &admin_cap, @0x111);

    let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, ctx);
    let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, ctx);
    cetus_live::open_position_with_liquidity_entry(
        &cfg,
        &clmm_cfg,
        &mut pool,
        coin_a_in,
        coin_b_in,
        i32::as_u32(pool_tests::nt(1_000)),
        i32::as_u32(pool_tests::pt(1_000)),
        10_000,
        true,
        &clock,
        ctx,
    );

    transfer::public_transfer(cfg, @0x1);
    transfer::public_transfer(admin_cap, @0x1);
    cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
}

#[test]
fun open_entry_wrapper_succeeds() {
    let ctx = &mut tx_context::dummy();
    let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(ctx);

    let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
        100,
        tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
        2000,
        0,
        &clock,
        ctx,
    );

    let (mut cfg, admin_cap) = vault_config::new(0, 0, ctx);
    let pool_id = object::id(&pool);
    vault_config::set_cetus_pool_id(&mut cfg, &admin_cap, object::id_to_address(&pool_id));

    let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, ctx);
    let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, ctx);
    cetus_live::open_position_with_liquidity_entry(
        &cfg,
        &clmm_cfg,
        &mut pool,
        coin_a_in,
        coin_b_in,
        i32::as_u32(pool_tests::nt(1_000)),
        i32::as_u32(pool_tests::pt(1_000)),
        10_000,
        true,
        &clock,
        ctx,
    );

    transfer::public_transfer(cfg, @0x1);
    transfer::public_transfer(admin_cap, @0x1);
    cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
}

#[test]
fun close_entry_wrapper_succeeds() {
    let ctx = &mut tx_context::dummy();
    let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(ctx);

    let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
        100,
        tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
        2000,
        0,
        &clock,
        ctx,
    );

    let (mut cfg, admin_cap) = vault_config::new(0, 0, ctx);
    let pool_id = object::id(&pool);
    vault_config::set_cetus_pool_id(&mut cfg, &admin_cap, object::id_to_address(&pool_id));

    let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, ctx);
    let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, ctx);
    let (position_nft, change_a, change_b) = cetus_live::open_position_with_liquidity(
        &cfg,
        &clmm_cfg,
        &mut pool,
        coin_a_in,
        coin_b_in,
        i32::as_u32(pool_tests::nt(1_000)),
        i32::as_u32(pool_tests::pt(1_000)),
        10_000,
        true,
        &clock,
        ctx,
    );
    assert!(position::liquidity(&position_nft) > 0, 0);

    cetus_live::close_position_and_withdraw_entry(
        &cfg,
        &clmm_cfg,
        &mut pool,
        position_nft,
        &clock,
        ctx,
    );

    transfer::public_transfer(change_a, @0x1);
    transfer::public_transfer(change_b, @0x1);
    transfer::public_transfer(cfg, @0x1);
    transfer::public_transfer(admin_cap, @0x1);
    cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
}

#[test, expected_failure(abort_code = errors::E_ADAPTER_NOT_IMPLEMENTED, location = self_driving_yield::cetus_live)]
fun open_aborts_when_adapter_not_enabled() {
    let ctx = &mut tx_context::dummy();
    let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(ctx);

    let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
        100,
        tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
        2000,
        0,
        &clock,
        ctx,
    );

    let (cfg, admin_cap) = vault_config::new(0, 0, ctx);
    let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, ctx);
    let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, ctx);
    cetus_live::open_position_with_liquidity_entry(
        &cfg,
        &clmm_cfg,
        &mut pool,
        coin_a_in,
        coin_b_in,
        i32::as_u32(pool_tests::nt(1_000)),
        i32::as_u32(pool_tests::pt(1_000)),
        10_000,
        true,
        &clock,
        ctx,
    );

    transfer::public_transfer(cfg, @0x1);
    transfer::public_transfer(admin_cap, @0x1);
    cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
}

#[test, expected_failure(abort_code = errors::E_ZERO_AMOUNT, location = self_driving_yield::cetus_live)]
fun open_aborts_on_zero_amount() {
    let ctx = &mut tx_context::dummy();
    let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(ctx);

    let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
        100,
        tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
        2000,
        0,
        &clock,
        ctx,
    );

    let (mut cfg, admin_cap) = vault_config::new(0, 0, ctx);
    let pool_id = object::id(&pool);
    vault_config::set_cetus_pool_id(&mut cfg, &admin_cap, object::id_to_address(&pool_id));

    let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, ctx);
    let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, ctx);
    cetus_live::open_position_with_liquidity_entry(
        &cfg,
        &clmm_cfg,
        &mut pool,
        coin_a_in,
        coin_b_in,
        i32::as_u32(pool_tests::nt(1_000)),
        i32::as_u32(pool_tests::pt(1_000)),
        0,
        true,
        &clock,
        ctx,
    );

    transfer::public_transfer(cfg, @0x1);
    transfer::public_transfer(admin_cap, @0x1);
    cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
}

#[test, expected_failure(abort_code = errors::E_ZERO_AMOUNT, location = self_driving_yield::cetus_live)]
fun close_aborts_when_position_has_zero_liquidity() {
    let ctx = &mut tx_context::dummy();
    let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(ctx);

    let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
        100,
        tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
        2000,
        0,
        &clock,
        ctx,
    );

    let (mut cfg, admin_cap) = vault_config::new(0, 0, ctx);
    let pool_id = object::id(&pool);
    vault_config::set_cetus_pool_id(&mut cfg, &admin_cap, object::id_to_address(&pool_id));

    let position_nft = cetus_amm::open_position(
        &clmm_cfg,
        &mut pool,
        i32::as_u32(pool_tests::nt(1_000)),
        i32::as_u32(pool_tests::pt(1_000)),
        ctx,
    );
    cetus_live::close_position_and_withdraw_entry(
        &cfg,
        &clmm_cfg,
        &mut pool,
        position_nft,
        &clock,
        ctx,
    );

    transfer::public_transfer(cfg, @0x1);
    transfer::public_transfer(admin_cap, @0x1);
    cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
}

#[test, expected_failure(abort_code = errors::E_OBJECT_MISMATCH, location = self_driving_yield::cetus_live)]
fun close_aborts_when_pool_mismatches_config() {
    let ctx = &mut tx_context::dummy();
    let (clock, clmm_admin_cap, clmm_cfg) = init_clmm(ctx);

    let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
        100,
        tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
        2000,
        0,
        &clock,
        ctx,
    );

    let (mut cfg, admin_cap) = vault_config::new(0, 0, ctx);
    vault_config::set_cetus_pool_id(&mut cfg, &admin_cap, @0x111);

    let position_nft = cetus_amm::open_position(
        &clmm_cfg,
        &mut pool,
        i32::as_u32(pool_tests::nt(1_000)),
        i32::as_u32(pool_tests::pt(1_000)),
        ctx,
    );
    cetus_live::close_position_and_withdraw_entry(
        &cfg,
        &clmm_cfg,
        &mut pool,
        position_nft,
        &clock,
        ctx,
    );

    transfer::public_transfer(cfg, @0x1);
    transfer::public_transfer(admin_cap, @0x1);
    cleanup_clmm(pool, clmm_admin_cap, clmm_cfg, clock);
}
