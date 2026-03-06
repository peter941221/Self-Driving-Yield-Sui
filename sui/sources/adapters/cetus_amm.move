module self_driving_yield::cetus_amm;

use self_driving_yield::config;

use cetus_clmm::config::GlobalConfig;
use cetus_clmm::pool;
use cetus_clmm::position::Position;
use sui::balance;
use sui::clock::Clock;
use sui::coin;

/// Returns true when the Cetus pool id is configured (P2).
public fun is_available(cfg: &config::Config): bool {
    config::cetus_pool_id(cfg) != @0x0
}

/// Open a CLMM position NFT on Cetus.
public fun open_position<CoinTypeA, CoinTypeB>(
    clmm_cfg: &GlobalConfig,
    clmm_pool: &mut pool::Pool<CoinTypeA, CoinTypeB>,
    tick_lower: u32,
    tick_upper: u32,
    ctx: &mut TxContext,
): Position {
    pool::open_position(clmm_cfg, clmm_pool, tick_lower, tick_upper, ctx)
}

/// Add liquidity by fixing one-side coin amount, and repay in the same PTB.
/// Returns (change_a, change_b).
public fun add_liquidity_fix_coin_and_repay<CoinTypeA, CoinTypeB>(
    clmm_cfg: &GlobalConfig,
    clmm_pool: &mut pool::Pool<CoinTypeA, CoinTypeB>,
    position_nft: &mut Position,
    coin_a_in: coin::Coin<CoinTypeA>,
    coin_b_in: coin::Coin<CoinTypeB>,
    amount: u64,
    fix_amount_a: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): (coin::Coin<CoinTypeA>, coin::Coin<CoinTypeB>) {
    let receipt = pool::add_liquidity_fix_coin<CoinTypeA, CoinTypeB>(
        clmm_cfg,
        clmm_pool,
        position_nft,
        amount,
        fix_amount_a,
        clock,
    );

    let (pay_a, pay_b) = pool::add_liquidity_pay_amount<CoinTypeA, CoinTypeB>(&receipt);

    let mut bal_a = coin::into_balance(coin_a_in);
    let mut bal_b = coin::into_balance(coin_b_in);

    let pay_bal_a = if (pay_a > 0) {
        balance::split(&mut bal_a, pay_a)
    } else {
        balance::zero()
    };
    let pay_bal_b = if (pay_b > 0) {
        balance::split(&mut bal_b, pay_b)
    } else {
        balance::zero()
    };

    pool::repay_add_liquidity<CoinTypeA, CoinTypeB>(clmm_cfg, clmm_pool, pay_bal_a, pay_bal_b, receipt);

    (coin::from_balance(bal_a, ctx), coin::from_balance(bal_b, ctx))
}

/// Remove liquidity from a position and return the withdrawn coins.
public fun remove_liquidity_to_coins<CoinTypeA, CoinTypeB>(
    clmm_cfg: &GlobalConfig,
    clmm_pool: &mut pool::Pool<CoinTypeA, CoinTypeB>,
    position_nft: &mut Position,
    delta_liquidity: u128,
    clock: &Clock,
    ctx: &mut TxContext,
): (coin::Coin<CoinTypeA>, coin::Coin<CoinTypeB>) {
    let (bal_a, bal_b) = pool::remove_liquidity<CoinTypeA, CoinTypeB>(
        clmm_cfg,
        clmm_pool,
        position_nft,
        delta_liquidity,
        clock,
    );
    (coin::from_balance(bal_a, ctx), coin::from_balance(bal_b, ctx))
}

/// Swap exact input CoinTypeA -> CoinTypeB via Cetus flash swap (repays in the same PTB).
/// Returns (coin_b_out, coin_a_change).
public fun swap_exact_in_a_to_b<CoinTypeA, CoinTypeB>(
    clmm_cfg: &GlobalConfig,
    clmm_pool: &mut pool::Pool<CoinTypeA, CoinTypeB>,
    coin_a_in: coin::Coin<CoinTypeA>,
    min_b_out: u64,
    sqrt_price_limit: u128,
    clock: &Clock,
    ctx: &mut TxContext,
): (coin::Coin<CoinTypeB>, coin::Coin<CoinTypeA>) {
    let amount_in = coin::value(&coin_a_in);
    let (bal_out_a, bal_out_b, receipt) = pool::flash_swap<CoinTypeA, CoinTypeB>(
        clmm_cfg,
        clmm_pool,
        true,
        true,
        amount_in,
        sqrt_price_limit,
        clock,
    );

    let out_b = balance::value(&bal_out_b);
    assert!(out_b >= min_b_out, 0);

    let pay_amount = pool::swap_pay_amount<CoinTypeA, CoinTypeB>(&receipt);
    let mut pay_a = coin::into_balance(coin_a_in);
    let pay_exact = if (pay_amount > 0) { balance::split(&mut pay_a, pay_amount) } else { balance::zero() };
    pool::repay_flash_swap<CoinTypeA, CoinTypeB>(clmm_cfg, clmm_pool, pay_exact, balance::zero(), receipt);

    balance::destroy_zero(bal_out_a);

    (coin::from_balance(bal_out_b, ctx), coin::from_balance(pay_a, ctx))
}

/// Swap exact input CoinTypeB -> CoinTypeA via Cetus flash swap (repays in the same PTB).
/// Returns (coin_a_out, coin_b_change).
public fun swap_exact_in_b_to_a<CoinTypeA, CoinTypeB>(
    clmm_cfg: &GlobalConfig,
    clmm_pool: &mut pool::Pool<CoinTypeA, CoinTypeB>,
    coin_b_in: coin::Coin<CoinTypeB>,
    min_a_out: u64,
    sqrt_price_limit: u128,
    clock: &Clock,
    ctx: &mut TxContext,
): (coin::Coin<CoinTypeA>, coin::Coin<CoinTypeB>) {
    let amount_in = coin::value(&coin_b_in);
    let (bal_out_a, bal_out_b, receipt) = pool::flash_swap<CoinTypeA, CoinTypeB>(
        clmm_cfg,
        clmm_pool,
        false,
        true,
        amount_in,
        sqrt_price_limit,
        clock,
    );

    let out_a = balance::value(&bal_out_a);
    assert!(out_a >= min_a_out, 0);

    let pay_amount = pool::swap_pay_amount<CoinTypeA, CoinTypeB>(&receipt);
    let mut pay_b = coin::into_balance(coin_b_in);
    let pay_exact = if (pay_amount > 0) { balance::split(&mut pay_b, pay_amount) } else { balance::zero() };
    pool::repay_flash_swap<CoinTypeA, CoinTypeB>(clmm_cfg, clmm_pool, balance::zero(), pay_exact, receipt);

    balance::destroy_zero(bal_out_b);

    (coin::from_balance(bal_out_a, ctx), coin::from_balance(pay_b, ctx))
}

/// Return current (amount_a, amount_b) implied by the position liquidity and pool price.
public fun get_position_amounts<CoinTypeA, CoinTypeB>(
    clmm_pool: &pool::Pool<CoinTypeA, CoinTypeB>,
    position_nft: &Position,
): (u64, u64) {
    pool::get_position_amounts_v2<CoinTypeA, CoinTypeB>(clmm_pool, object::id(position_nft))
}
