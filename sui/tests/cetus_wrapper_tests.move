module self_driving_yield::cetus_wrapper_tests;

use cetus_clmm::config::{Self, GlobalConfig, AdminCap, new_global_config_for_test};
use cetus_clmm::pool::Pool;
use cetus_clmm::pool_tests;
use cetus_clmm::position;
use cetus_clmm::tick_math;
use integer_mate::i32;
use sui::clock::{Self, Clock};
use sui::coin;

use self_driving_yield::cetus_amm;

fun init_clmm(ctx: &mut TxContext): (Clock, AdminCap, GlobalConfig) {
    let clock = clock::create_for_testing(ctx);
    let (cap, mut cfg) = new_global_config_for_test(ctx, 2000);
    config::add_role(&cap, &mut cfg, @0x0, 0);
    (clock, cap, cfg)
}

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
fun open_position_and_get_amounts_wrapper_work() {
    let ctx = &mut tx_context::dummy();
    let (clock, cap, cfg) = init_clmm(ctx);

    let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
        100,
        tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
        2000,
        0,
        &clock,
        ctx,
    );
    let position = cetus_amm::open_position(
        &cfg,
        &mut pool,
        i32::as_u32(pool_tests::nt(1_000)),
        i32::as_u32(pool_tests::pt(1_000)),
        ctx,
    );

    let (amount_a, amount_b) = cetus_amm::get_position_amounts(&pool, &position);
    assert!(amount_a == 0, 0);
    assert!(amount_b == 0, 0);
    assert!(position::liquidity(&position) == 0, 0);

    transfer::public_transfer(position, @0x1);
    cleanup_clmm(pool, cap, cfg, clock);
}

#[test]
fun add_and_remove_liquidity_wrappers_return_expected_coins() {
    let ctx = &mut tx_context::dummy();
    let (clock, cap, cfg) = init_clmm(ctx);

    let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
        100,
        tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
        2000,
        0,
        &clock,
        ctx,
    );
    let mut position = cetus_amm::open_position(
        &cfg,
        &mut pool,
        i32::as_u32(pool_tests::nt(1_000)),
        i32::as_u32(pool_tests::pt(1_000)),
        ctx,
    );

    let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(100_000, ctx);
    let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(100_000, ctx);
    let (change_a, change_b) = cetus_amm::add_liquidity_fix_coin_and_repay(
        &cfg,
        &mut pool,
        &mut position,
        coin_a_in,
        coin_b_in,
        10_000,
        true,
        &clock,
        ctx,
    );

    let (amount_a, amount_b) = cetus_amm::get_position_amounts(&pool, &position);
    assert!(amount_a > 0 || amount_b > 0, 0);
    assert!(position::liquidity(&position) > 0, 0);
    assert!(coin::value(&change_a) < 100_000, 0);
    assert!(coin::value(&change_b) <= 100_000, 0);

    let liquidity = position::liquidity(&position);
    let (out_a, out_b) = cetus_amm::remove_liquidity_to_coins(
        &cfg,
        &mut pool,
        &mut position,
        liquidity,
        &clock,
        ctx,
    );
    let (after_a, after_b) = cetus_amm::get_position_amounts(&pool, &position);
    assert!(after_a == 0, 0);
    assert!(after_b == 0, 0);
    assert!(coin::value(&out_a) > 0 || coin::value(&out_b) > 0, 0);

    transfer::public_transfer(change_a, @0x1);
    transfer::public_transfer(change_b, @0x1);
    transfer::public_transfer(out_a, @0x1);
    transfer::public_transfer(out_b, @0x1);
    transfer::public_transfer(position, @0x1);
    cleanup_clmm(pool, cap, cfg, clock);
}

#[test]
fun swap_wrappers_cover_both_directions() {
    let ctx = &mut tx_context::dummy();
    let (clock, cap, cfg) = init_clmm(ctx);

    let mut pool = pool_tests::create_pool<pool_tests::CoinA, pool_tests::CoinB>(
        100,
        tick_math::get_sqrt_price_at_tick(pool_tests::pt(0)),
        2000,
        0,
        &clock,
        ctx,
    );
    let position = pool_tests::open_position_with_liquidity(
        &cfg,
        &mut pool,
        pool_tests::nt(1_000),
        pool_tests::pt(1_000),
        1_000_000,
        &clock,
        ctx,
    );

    let coin_a_in = coin::mint_for_testing<pool_tests::CoinA>(10_000, ctx);
    let (coin_b_out, coin_a_change) = cetus_amm::swap_exact_in_a_to_b(
        &cfg,
        &mut pool,
        coin_a_in,
        1,
        tick_math::min_sqrt_price(),
        &clock,
        ctx,
    );
    assert!(coin::value(&coin_b_out) > 0, 0);
    assert!(coin::value(&coin_a_change) < 10_000, 0);

    let coin_b_in = coin::mint_for_testing<pool_tests::CoinB>(10_000, ctx);
    let (coin_a_out, coin_b_change) = cetus_amm::swap_exact_in_b_to_a(
        &cfg,
        &mut pool,
        coin_b_in,
        1,
        tick_math::max_sqrt_price(),
        &clock,
        ctx,
    );
    assert!(coin::value(&coin_a_out) > 0, 0);
    assert!(coin::value(&coin_b_change) < 10_000, 0);

    transfer::public_transfer(coin_b_out, @0x1);
    transfer::public_transfer(coin_a_change, @0x1);
    transfer::public_transfer(coin_a_out, @0x1);
    transfer::public_transfer(coin_b_change, @0x1);
    transfer::public_transfer(position, @0x1);
    cleanup_clmm(pool, cap, cfg, clock);
}
