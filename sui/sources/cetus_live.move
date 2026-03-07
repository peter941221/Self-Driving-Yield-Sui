module self_driving_yield::cetus_live;

use cetus_clmm::config::GlobalConfig;
use cetus_clmm::pool::{Self, Pool};
use cetus_clmm::position::{Self, Position};
use self_driving_yield::cetus_amm;
use self_driving_yield::config;
use self_driving_yield::entrypoints;
use self_driving_yield::errors;
use self_driving_yield::queue;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::event;

public struct CetusPositionOpenedEvent has copy, drop, store {
    sender: address,
    configured_pool_id: address,
    actual_pool_id: address,
    position_id: address,
    coin_a_in: u64,
    coin_b_in: u64,
    change_a: u64,
    change_b: u64,
    liquidity: u128,
    tick_lower: u32,
    tick_upper: u32,
    fix_amount_a: bool,
}

public struct CetusPositionClosedEvent has copy, drop, store {
    sender: address,
    configured_pool_id: address,
    actual_pool_id: address,
    position_id: address,
    coin_a_out: u64,
    coin_b_out: u64,
    liquidity_removed: u128,
}

fun pool_address<CoinTypeA, CoinTypeB>(clmm_pool: &Pool<CoinTypeA, CoinTypeB>): address {
    let pool_id = object::id(clmm_pool);
    object::id_to_address(&pool_id)
}

fun position_address(position_nft: &Position): address {
    let position_id = object::id(position_nft);
    object::id_to_address(&position_id)
}

fun assert_pool_matches_config<CoinTypeA, CoinTypeB>(
    cfg: &config::Config,
    clmm_pool: &Pool<CoinTypeA, CoinTypeB>,
) {
    assert!(cetus_amm::is_available(cfg), errors::e_adapter_not_implemented());
    assert!(config::cetus_pool_id(cfg) == pool_address(clmm_pool), errors::e_object_mismatch());
}

fun open_position_with_liquidity_details<CoinTypeA, CoinTypeB>(
    cfg: &config::Config,
    clmm_cfg: &GlobalConfig,
    clmm_pool: &mut Pool<CoinTypeA, CoinTypeB>,
    coin_a_in: coin::Coin<CoinTypeA>,
    coin_b_in: coin::Coin<CoinTypeB>,
    tick_lower: u32,
    tick_upper: u32,
    amount: u64,
    fix_amount_a: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): (Position, coin::Coin<CoinTypeA>, coin::Coin<CoinTypeB>, address, u64, u64) {
    assert!(amount > 0, errors::e_zero_amount());
    assert_pool_matches_config(cfg, clmm_pool);

    let sender = tx_context::sender(ctx);
    let configured_pool_id = config::cetus_pool_id(cfg);
    let actual_pool_id = pool_address(clmm_pool);
    let coin_a_value = coin::value(&coin_a_in);
    let coin_b_value = coin::value(&coin_b_in);

    let mut position_nft = cetus_amm::open_position(
        clmm_cfg,
        clmm_pool,
        tick_lower,
        tick_upper,
        ctx,
    );
    let (change_a, change_b) = cetus_amm::add_liquidity_fix_coin_and_repay(
        clmm_cfg,
        clmm_pool,
        &mut position_nft,
        coin_a_in,
        coin_b_in,
        amount,
        fix_amount_a,
        clock,
        ctx,
    );

    let position_id = position_address(&position_nft);
    let liquidity = position::liquidity(&position_nft);
    let change_a_value = coin::value(&change_a);
    let change_b_value = coin::value(&change_b);
    let principal_a = coin_a_value - change_a_value;
    let principal_b = coin_b_value - change_b_value;
    event::emit(CetusPositionOpenedEvent {
        sender,
        configured_pool_id,
        actual_pool_id,
        position_id,
        coin_a_in: coin_a_value,
        coin_b_in: coin_b_value,
        change_a: change_a_value,
        change_b: change_b_value,
        liquidity,
        tick_lower,
        tick_upper,
        fix_amount_a,
    });

    (position_nft, change_a, change_b, position_id, principal_a, principal_b)
}

public fun open_position_with_liquidity<CoinTypeA, CoinTypeB>(
    cfg: &config::Config,
    clmm_cfg: &GlobalConfig,
    clmm_pool: &mut Pool<CoinTypeA, CoinTypeB>,
    coin_a_in: coin::Coin<CoinTypeA>,
    coin_b_in: coin::Coin<CoinTypeB>,
    tick_lower: u32,
    tick_upper: u32,
    amount: u64,
    fix_amount_a: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): (Position, coin::Coin<CoinTypeA>, coin::Coin<CoinTypeB>) {
    let (position_nft, change_a, change_b, _, _, _) = open_position_with_liquidity_details(
        cfg,
        clmm_cfg,
        clmm_pool,
        coin_a_in,
        coin_b_in,
        tick_lower,
        tick_upper,
        amount,
        fix_amount_a,
        clock,
        ctx,
    );
    (position_nft, change_a, change_b)
}

fun close_position_and_withdraw_details<CoinTypeA, CoinTypeB>(
    cfg: &config::Config,
    clmm_cfg: &GlobalConfig,
    clmm_pool: &mut Pool<CoinTypeA, CoinTypeB>,
    position_nft: Position,
    clock: &Clock,
    ctx: &mut TxContext,
): (coin::Coin<CoinTypeA>, coin::Coin<CoinTypeB>, address) {
    assert_pool_matches_config(cfg, clmm_pool);

    let sender = tx_context::sender(ctx);
    let configured_pool_id = config::cetus_pool_id(cfg);
    let actual_pool_id = pool_address(clmm_pool);
    let mut position_nft = position_nft;
    let position_id = position_address(&position_nft);
    let liquidity_removed = position::liquidity(&position_nft);
    assert!(liquidity_removed > 0, errors::e_zero_amount());

    let (coin_a_out, coin_b_out) = cetus_amm::remove_liquidity_to_coins(
        clmm_cfg,
        clmm_pool,
        &mut position_nft,
        liquidity_removed,
        clock,
        ctx,
    );
    let coin_a_out_value = coin::value(&coin_a_out);
    let coin_b_out_value = coin::value(&coin_b_out);
    pool::close_position(clmm_cfg, clmm_pool, position_nft);

    event::emit(CetusPositionClosedEvent {
        sender,
        configured_pool_id,
        actual_pool_id,
        position_id,
        coin_a_out: coin_a_out_value,
        coin_b_out: coin_b_out_value,
        liquidity_removed,
    });

    (coin_a_out, coin_b_out, position_id)
}

public fun close_position_and_withdraw<CoinTypeA, CoinTypeB>(
    cfg: &config::Config,
    clmm_cfg: &GlobalConfig,
    clmm_pool: &mut Pool<CoinTypeA, CoinTypeB>,
    position_nft: Position,
    clock: &Clock,
    ctx: &mut TxContext,
): (coin::Coin<CoinTypeA>, coin::Coin<CoinTypeB>) {
    let (coin_a_out, coin_b_out, _) = close_position_and_withdraw_details(
        cfg,
        clmm_cfg,
        clmm_pool,
        position_nft,
        clock,
        ctx,
    );
    (coin_a_out, coin_b_out)
}

public fun open_position_into_vault<BASE, CoinTypeA, CoinTypeB>(
    v: &mut entrypoints::Vault<BASE>,
    cfg: &config::Config,
    clmm_cfg: &GlobalConfig,
    clmm_pool: &mut Pool<CoinTypeA, CoinTypeB>,
    coin_a_in: coin::Coin<CoinTypeA>,
    coin_b_in: coin::Coin<CoinTypeB>,
    tick_lower: u32,
    tick_upper: u32,
    amount: u64,
    fix_amount_a: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): (coin::Coin<CoinTypeA>, coin::Coin<CoinTypeB>) {
    let (position_nft, change_a, change_b, position_id, principal_a, principal_b) = open_position_with_liquidity_details(
        cfg,
        clmm_cfg,
        clmm_pool,
        coin_a_in,
        coin_b_in,
        tick_lower,
        tick_upper,
        amount,
        fix_amount_a,
        clock,
        ctx,
    );
    entrypoints::store_cetus_position(v, position_nft);
    entrypoints::record_cetus_live_open(
        v,
        cfg,
        position_id,
        principal_a,
        principal_b,
        clock::timestamp_ms(clock),
    );
    (change_a, change_b)
}

public fun close_stored_position_from_vault<BASE, CoinTypeA, CoinTypeB>(
    v: &mut entrypoints::Vault<BASE>,
    cfg: &config::Config,
    clmm_cfg: &GlobalConfig,
    clmm_pool: &mut Pool<CoinTypeA, CoinTypeB>,
    clock: &Clock,
    ctx: &mut TxContext,
): (coin::Coin<CoinTypeA>, coin::Coin<CoinTypeB>) {
    let position_nft = entrypoints::take_cetus_position(v);
    let (coin_a_out, coin_b_out, position_id) = close_position_and_withdraw_details(
        cfg,
        clmm_cfg,
        clmm_pool,
        position_nft,
        clock,
        ctx,
    );
    entrypoints::record_cetus_live_close(v, cfg, position_id, clock::timestamp_ms(clock));
    (coin_a_out, coin_b_out)
}

public fun rebalance_live<BASE, CoinTypeA, CoinTypeB>(
    v: &mut entrypoints::Vault<BASE>,
    q: &mut queue::WithdrawalQueue,
    cfg: &config::Config,
    clmm_pool: &Pool<CoinTypeA, CoinTypeB>,
    spot_price: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (u64, option::Option<coin::Coin<BASE>>, u64, u64) {
    let (moved, bounty_opt) = entrypoints::cycle(v, q, cfg, spot_price, clock, ctx);
    assert_pool_matches_config(cfg, clmm_pool);

    if (entrypoints::has_stored_cetus_position(v)) {
        let position_ref = entrypoints::borrow_stored_cetus_position(v);
        let position_id = entrypoints::stored_cetus_position_id(v);
        let (amount_a, amount_b) = cetus_amm::get_position_amounts(clmm_pool, position_ref);
        entrypoints::record_cetus_live_snapshot(v, cfg, position_id, amount_a, amount_b, clock::timestamp_ms(clock));
        (moved, bounty_opt, amount_a, amount_b)
    } else {
        (moved, bounty_opt, 0, 0)
    }
}

fun should_close_live_position<BASE>(v: &entrypoints::Vault<BASE>, q: &queue::WithdrawalQueue): bool {
    if (!entrypoints::has_stored_cetus_position(v)) {
        return false
    };
    if (entrypoints::is_only_unwind_mode(v)) {
        return true
    };
    let queued_need = queue::total_ready_usdc(queue::state(q)) + queue::total_pending_usdc(queue::state(q));
    queued_need > entrypoints::treasury_usdc(v)
}

public fun cycle_live<BASE, CoinTypeA, CoinTypeB>(
    v: &mut entrypoints::Vault<BASE>,
    q: &mut queue::WithdrawalQueue,
    cfg: &config::Config,
    clmm_cfg: &GlobalConfig,
    clmm_pool: &mut Pool<CoinTypeA, CoinTypeB>,
    spot_price: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (u64, option::Option<coin::Coin<BASE>>, coin::Coin<CoinTypeA>, coin::Coin<CoinTypeB>, u64, u64, u64) {
    let should_close_before = should_close_live_position(v, q);
    let (moved, bounty_opt, amount_a, amount_b) = rebalance_live(v, q, cfg, clmm_pool, spot_price, clock, ctx);
    if (should_close_before || should_close_live_position(v, q)) {
        let (coin_a_out, coin_b_out) = close_stored_position_from_vault(v, cfg, clmm_cfg, clmm_pool, clock, ctx);
        (moved, bounty_opt, coin_a_out, coin_b_out, 3, amount_a, amount_b)
    } else {
        (moved, bounty_opt, coin::zero<CoinTypeA>(ctx), coin::zero<CoinTypeB>(ctx), 2, amount_a, amount_b)
    }
}

#[allow(lint(self_transfer))]
public fun open_position_with_liquidity_entry<CoinTypeA, CoinTypeB>(
    cfg: &config::Config,
    clmm_cfg: &GlobalConfig,
    clmm_pool: &mut Pool<CoinTypeA, CoinTypeB>,
    coin_a_in: coin::Coin<CoinTypeA>,
    coin_b_in: coin::Coin<CoinTypeB>,
    tick_lower: u32,
    tick_upper: u32,
    amount: u64,
    fix_amount_a: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (position_nft, change_a, change_b) = open_position_with_liquidity(
        cfg,
        clmm_cfg,
        clmm_pool,
        coin_a_in,
        coin_b_in,
        tick_lower,
        tick_upper,
        amount,
        fix_amount_a,
        clock,
        ctx,
    );
    transfer::public_transfer(position_nft, tx_context::sender(ctx));
    transfer::public_transfer(change_a, tx_context::sender(ctx));
    transfer::public_transfer(change_b, tx_context::sender(ctx));
}

#[allow(lint(self_transfer))]
public fun open_position_into_vault_entry<BASE, CoinTypeA, CoinTypeB>(
    v: &mut entrypoints::Vault<BASE>,
    cfg: &config::Config,
    clmm_cfg: &GlobalConfig,
    clmm_pool: &mut Pool<CoinTypeA, CoinTypeB>,
    coin_a_in: coin::Coin<CoinTypeA>,
    coin_b_in: coin::Coin<CoinTypeB>,
    tick_lower: u32,
    tick_upper: u32,
    amount: u64,
    fix_amount_a: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (change_a, change_b) = open_position_into_vault(
        v,
        cfg,
        clmm_cfg,
        clmm_pool,
        coin_a_in,
        coin_b_in,
        tick_lower,
        tick_upper,
        amount,
        fix_amount_a,
        clock,
        ctx,
    );
    transfer::public_transfer(change_a, tx_context::sender(ctx));
    transfer::public_transfer(change_b, tx_context::sender(ctx));
}


#[allow(lint(self_transfer))]
public fun close_position_and_withdraw_entry<CoinTypeA, CoinTypeB>(
    cfg: &config::Config,
    clmm_cfg: &GlobalConfig,
    clmm_pool: &mut Pool<CoinTypeA, CoinTypeB>,
    position_nft: Position,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (coin_a_out, coin_b_out) = close_position_and_withdraw(
        cfg,
        clmm_cfg,
        clmm_pool,
        position_nft,
        clock,
        ctx,
    );
    transfer::public_transfer(coin_a_out, tx_context::sender(ctx));
    transfer::public_transfer(coin_b_out, tx_context::sender(ctx));
}

#[allow(lint(self_transfer))]
public fun close_stored_position_from_vault_entry<BASE, CoinTypeA, CoinTypeB>(
    v: &mut entrypoints::Vault<BASE>,
    cfg: &config::Config,
    clmm_cfg: &GlobalConfig,
    clmm_pool: &mut Pool<CoinTypeA, CoinTypeB>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (coin_a_out, coin_b_out) = close_stored_position_from_vault(v, cfg, clmm_cfg, clmm_pool, clock, ctx);
    transfer::public_transfer(coin_a_out, tx_context::sender(ctx));
    transfer::public_transfer(coin_b_out, tx_context::sender(ctx));
}

#[allow(lint(self_transfer))]
public fun cycle_live_entry<BASE, CoinTypeA, CoinTypeB>(
    v: &mut entrypoints::Vault<BASE>,
    q: &mut queue::WithdrawalQueue,
    cfg: &config::Config,
    clmm_cfg: &GlobalConfig,
    clmm_pool: &mut Pool<CoinTypeA, CoinTypeB>,
    spot_price: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (_, bounty_opt, coin_a_out, coin_b_out, _, _, _) = cycle_live(v, q, cfg, clmm_cfg, clmm_pool, spot_price, clock, ctx);
    if (option::is_some(&bounty_opt)) {
        let bounty = option::destroy_some(bounty_opt);
        transfer::public_transfer(bounty, tx_context::sender(ctx));
    } else {
        option::destroy_none(bounty_opt);
    };
    if (coin::value(&coin_a_out) > 0) {
        transfer::public_transfer(coin_a_out, tx_context::sender(ctx));
    } else {
        coin::destroy_zero(coin_a_out);
    };
    if (coin::value(&coin_b_out) > 0) {
        transfer::public_transfer(coin_b_out, tx_context::sender(ctx));
    } else {
        coin::destroy_zero(coin_b_out);
    };
}
