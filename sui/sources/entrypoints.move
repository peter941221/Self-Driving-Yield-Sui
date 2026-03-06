module self_driving_yield::entrypoints;

use self_driving_yield::cetus_amm;
use self_driving_yield::config;
use self_driving_yield::errors;
use self_driving_yield::math;
use self_driving_yield::oracle;
use self_driving_yield::perp_hedge;
use self_driving_yield::queue;
use self_driving_yield::rebalancer;
use self_driving_yield::sdye;
use self_driving_yield::vault;
use self_driving_yield::yield_source;
use sui::balance;
use sui::clock;
use sui::coin;

public struct Vault<phantom BASE> has key, store {
    id: UID,
    state: vault::VaultState,
    oracle: oracle::OracleState,
    treasury: balance::Balance<BASE>,
    cetus_balance: balance::Balance<BASE>,
    yield_balance: balance::Balance<BASE>,
    hedge_margin_balance: balance::Balance<BASE>,
    cetus_pool_id: address,
    cetus_deployed_usdc: u64,
    cetus_last_rebalance_ts_ms: u64,
    yield_receipt_id: address,
    yield_deployed_usdc: u64,
    yield_last_rebalance_ts_ms: u64,
    hedge_position_id: address,
    hedge_notional_usdc: u64,
    hedge_margin_usdc: u64,
    hedge_last_rebalance_ts_ms: u64,
    last_rebalance_used_flash: bool,
    sdye_treasury: coin::TreasuryCap<sdye::SDYE>,
}

fun total_deployed_internal<BASE>(v: &Vault<BASE>): u64 {
    let cetus = balance::value(&v.cetus_balance);
    let y = balance::value(&v.yield_balance);
    let hedge = balance::value(&v.hedge_margin_balance);
    math::safe_add(math::safe_add(cetus, y), hedge)
}

fun sync_strategy_metadata<BASE>(v: &mut Vault<BASE>, cfg: &config::Config, ts_ms: u64) {
    let cetus = balance::value(&v.cetus_balance);
    v.cetus_deployed_usdc = cetus;
    v.cetus_last_rebalance_ts_ms = ts_ms;
    v.cetus_pool_id = if (cetus > 0 && cetus_amm::is_available(cfg)) { config::cetus_pool_id(cfg) } else { @0x0 };

    let y = balance::value(&v.yield_balance);
    v.yield_deployed_usdc = y;
    v.yield_last_rebalance_ts_ms = ts_ms;
    v.yield_receipt_id = if (y > 0 && yield_source::is_available(cfg)) { config::lending_market_id(cfg) } else { @0x0 };

    let hedge = balance::value(&v.hedge_margin_balance);
    v.hedge_margin_usdc = hedge;
    v.hedge_last_rebalance_ts_ms = ts_ms;
    if (hedge > 0 && perp_hedge::is_available(cfg) && cetus > 0) {
        v.hedge_position_id = config::perps_market_id(cfg);
        v.hedge_notional_usdc = cetus;
    } else {
        v.hedge_position_id = @0x0;
        v.hedge_notional_usdc = 0;
    }
}

fun assert_vault_synced<BASE>(v: &Vault<BASE>) {
    let treasury = balance::value(&v.treasury);
    let cetus = balance::value(&v.cetus_balance);
    let y = balance::value(&v.yield_balance);
    let hedge = balance::value(&v.hedge_margin_balance);
    let deployed = math::safe_add(math::safe_add(cetus, y), hedge);
    let total = math::safe_add(treasury, deployed);

    assert!(vault::treasury_usdc(&v.state) == treasury, errors::e_overflow());
    assert!(v.cetus_deployed_usdc == cetus, errors::e_overflow());
    assert!(v.yield_deployed_usdc == y, errors::e_overflow());
    assert!(v.hedge_margin_usdc == hedge, errors::e_overflow());
    assert!(vault::total_assets(&v.state) == total, errors::e_overflow());
}

fun move_treasury_to_balance<BASE>(
    treasury: &mut balance::Balance<BASE>,
    strategy: &mut balance::Balance<BASE>,
    amount: u64,
) {
    if (amount > 0) {
        let moved = balance::split(treasury, amount);
        balance::join(strategy, moved);
    }
}

fun move_balance_to_treasury<BASE>(
    strategy: &mut balance::Balance<BASE>,
    treasury: &mut balance::Balance<BASE>,
    amount: u64,
) {
    if (amount > 0) {
        let moved = balance::split(strategy, amount);
        balance::join(treasury, moved);
    }
}

fun unwind_to_cover_liquidity<BASE>(v: &mut Vault<BASE>, needed_treasury: u64) {
    let treasury = balance::value(&v.treasury);
    if (treasury >= needed_treasury) return;

    let mut deficit = needed_treasury - treasury;

    let hedge = balance::value(&v.hedge_margin_balance);
    let unwind_hedge = if (hedge < deficit) { hedge } else { deficit };
    move_balance_to_treasury(&mut v.hedge_margin_balance, &mut v.treasury, unwind_hedge);
    deficit = deficit - unwind_hedge;

    let y = balance::value(&v.yield_balance);
    let unwind_y = if (y < deficit) { y } else { deficit };
    move_balance_to_treasury(&mut v.yield_balance, &mut v.treasury, unwind_y);
    deficit = deficit - unwind_y;

    let cetus = balance::value(&v.cetus_balance);
    let unwind_cetus = if (cetus < deficit) { cetus } else { deficit };
    move_balance_to_treasury(&mut v.cetus_balance, &mut v.treasury, unwind_cetus);

    vault::set_treasury_usdc_for_testing(&mut v.state, balance::value(&v.treasury));
}

fun target_strategy_mix<BASE>(
    v: &Vault<BASE>,
    q: &queue::WithdrawalQueue,
    cfg: &config::Config,
): (u64, u64, u64) {
    let total_assets = vault::total_assets(&v.state);
    let queued_need = math::safe_add(
        queue::total_ready_usdc(queue::state(q)),
        queue::total_pending_usdc(queue::state(q)),
    );

    if (vault::is_only_unwind(&vault::risk_mode(&v.state))) {
        let target_yield = if (yield_source::is_available(cfg)) { balance::value(&v.yield_balance) } else { 0 };
        return (0, target_yield, 0)
    };

    let regime = oracle::current_regime(&v.oracle);
    let (yield_bps, lp_bps, buffer_bps) = vault::get_allocation(&regime);
    let buffer_target = math::mul_div(total_assets, buffer_bps, 10000);
    let lp_nominal = if (cetus_amm::is_available(cfg)) { math::mul_div(total_assets, lp_bps, 10000) } else { 0 };
    let hedge_margin_target = if (perp_hedge::is_available(cfg) && lp_nominal > 0) { perp_hedge::required_margin(lp_nominal) } else { 0 };
    let required_liquidity = math::safe_add(
        if (buffer_target > queued_need) { buffer_target } else { queued_need },
        hedge_margin_target,
    );
    let max_deployable = if (total_assets > required_liquidity) { total_assets - required_liquidity } else { 0 };
    let target_lp = if (lp_nominal < max_deployable) { lp_nominal } else { max_deployable };

    let yield_nominal = if (yield_source::is_available(cfg)) { math::mul_div(total_assets, yield_bps, 10000) } else { 0 };
    let remaining_after_lp = if (max_deployable > target_lp) { max_deployable - target_lp } else { 0 };
    let target_yield = if (yield_nominal < remaining_after_lp) { yield_nominal } else { remaining_after_lp };

    (target_lp, target_yield, hedge_margin_target)
}

fun rebalance_strategy_accounting<BASE>(
    v: &mut Vault<BASE>,
    q: &queue::WithdrawalQueue,
    cfg: &config::Config,
    ts_ms: u64,
) {
    if (!cetus_amm::is_available(cfg) && !yield_source::is_available(cfg) && !perp_hedge::is_available(cfg)) {
        v.last_rebalance_used_flash = false;
        sync_strategy_metadata(v, cfg, ts_ms);
        return
    };

    let (target_lp, target_yield, target_hedge) = target_strategy_mix(v, q, cfg);

    let current_lp = balance::value(&v.cetus_balance);
    let current_yield = balance::value(&v.yield_balance);
    let current_hedge = balance::value(&v.hedge_margin_balance);

    let lp_delta = if (current_lp > target_lp) { current_lp - target_lp } else { target_lp - current_lp };
    let yield_delta = if (current_yield > target_yield) { current_yield - target_yield } else { target_yield - current_yield };
    let hedge_delta = if (current_hedge > target_hedge) { current_hedge - target_hedge } else { target_hedge - current_hedge };
    let total_delta = math::safe_add(math::safe_add(lp_delta, yield_delta), hedge_delta);
    v.last_rebalance_used_flash = rebalancer::rebalance_flash(cfg, total_delta);
    let _ = if (!v.last_rebalance_used_flash) { rebalancer::rebalance_ptb(cfg, total_delta) } else { false };

    if (current_hedge > target_hedge) {
        move_balance_to_treasury(&mut v.hedge_margin_balance, &mut v.treasury, current_hedge - target_hedge)
    };
    if (current_yield > target_yield) {
        move_balance_to_treasury(&mut v.yield_balance, &mut v.treasury, current_yield - target_yield)
    };
    if (current_lp > target_lp) {
        move_balance_to_treasury(&mut v.cetus_balance, &mut v.treasury, current_lp - target_lp)
    };

    let next_lp = balance::value(&v.cetus_balance);
    let next_yield = balance::value(&v.yield_balance);
    let next_hedge = balance::value(&v.hedge_margin_balance);

    if (next_lp < target_lp) {
        move_treasury_to_balance(&mut v.treasury, &mut v.cetus_balance, target_lp - next_lp)
    };
    if (next_yield < target_yield) {
        move_treasury_to_balance(&mut v.treasury, &mut v.yield_balance, target_yield - next_yield)
    };
    if (next_hedge < target_hedge) {
        move_treasury_to_balance(&mut v.treasury, &mut v.hedge_margin_balance, target_hedge - next_hedge)
    };

    vault::set_treasury_usdc_for_testing(&mut v.state, balance::value(&v.treasury));
    sync_strategy_metadata(v, cfg, ts_ms);
}

public fun has_cetus_position<BASE>(v: &Vault<BASE>): bool { v.cetus_deployed_usdc > 0 }
public fun total_assets<BASE>(v: &Vault<BASE>): u64 { vault::total_assets(&v.state) }
public fun total_shares<BASE>(v: &Vault<BASE>): u64 { vault::total_shares(&v.state) }
public fun treasury_usdc<BASE>(v: &Vault<BASE>): u64 { vault::treasury_usdc(&v.state) }
public fun is_only_unwind_mode<BASE>(v: &Vault<BASE>): bool { vault::is_only_unwind(&vault::risk_mode(&v.state)) }
public fun safe_cycles_since_storm<BASE>(v: &Vault<BASE>): u64 { vault::safe_cycles_since_storm(&v.state) }
public fun cetus_pool_id<BASE>(v: &Vault<BASE>): address { v.cetus_pool_id }
public fun cetus_deployed_usdc<BASE>(v: &Vault<BASE>): u64 { v.cetus_deployed_usdc }
public fun cetus_last_rebalance_ts_ms<BASE>(v: &Vault<BASE>): u64 { v.cetus_last_rebalance_ts_ms }
public fun yield_receipt_id<BASE>(v: &Vault<BASE>): address { v.yield_receipt_id }
public fun yield_deployed_usdc<BASE>(v: &Vault<BASE>): u64 { v.yield_deployed_usdc }
public fun hedge_position_id<BASE>(v: &Vault<BASE>): address { v.hedge_position_id }
public fun hedge_notional_usdc<BASE>(v: &Vault<BASE>): u64 { v.hedge_notional_usdc }
public fun hedge_margin_usdc<BASE>(v: &Vault<BASE>): u64 { v.hedge_margin_usdc }
public fun last_rebalance_used_flash<BASE>(v: &Vault<BASE>): bool { v.last_rebalance_used_flash }
public fun deployed_balance<BASE>(v: &Vault<BASE>): u64 { total_deployed_internal(v) }

public fun bootstrap<BASE>(
    sdye_treasury: coin::TreasuryCap<sdye::SDYE>,
    min_cycle_interval_ms: u64,
    min_snapshot_interval_ms: u64,
    ctx: &mut TxContext,
) {
    let (cfg, cap) = config::new(min_cycle_interval_ms, min_snapshot_interval_ms, ctx);

    let v = Vault<BASE> {
        id: object::new(ctx),
        state: vault::new_state(),
        oracle: oracle::new(),
        treasury: balance::zero(),
        cetus_balance: balance::zero(),
        yield_balance: balance::zero(),
        hedge_margin_balance: balance::zero(),
        cetus_pool_id: @0x0,
        cetus_deployed_usdc: 0,
        cetus_last_rebalance_ts_ms: 0,
        yield_receipt_id: @0x0,
        yield_deployed_usdc: 0,
        yield_last_rebalance_ts_ms: 0,
        hedge_position_id: @0x0,
        hedge_notional_usdc: 0,
        hedge_margin_usdc: 0,
        hedge_last_rebalance_ts_ms: 0,
        last_rebalance_used_flash: false,
        sdye_treasury,
    };
    let q = queue::new_queue(ctx);

    transfer::share_object(v);
    transfer::public_share_object(q);
    transfer::public_share_object(cfg);
    transfer::public_transfer(cap, tx_context::sender(ctx));
}

public fun deposit<BASE>(
    v: &mut Vault<BASE>,
    base_in: coin::Coin<BASE>,
    _clock: &clock::Clock,
    ctx: &mut TxContext,
): coin::Coin<sdye::SDYE> {
    let assets_in = coin::value(&base_in);
    coin::put(&mut v.treasury, base_in);

    let shares_out = vault::deposit(&mut v.state, assets_in);
    assert_vault_synced(v);
    sdye::mint_shares(&mut v.sdye_treasury, shares_out, ctx)
}

public fun request_withdraw<BASE>(
    v: &mut Vault<BASE>,
    q: &mut queue::WithdrawalQueue,
    shares_in: coin::Coin<sdye::SDYE>,
    clock: &clock::Clock,
    ctx: &mut TxContext,
): (vault::WithdrawPlan, option::Option<coin::Coin<BASE>>) {
    let sender = tx_context::sender(ctx);
    let created_at_ms = clock::timestamp_ms(clock);
    let shares_amount = coin::value(&shares_in);

    let plan = vault::request_withdraw(
        &mut v.state,
        queue::state_mut(q),
        sender,
        shares_amount,
        created_at_ms,
    );

    if (vault::plan_is_instant(&plan)) {
        let burned = coin::burn(&mut v.sdye_treasury, shares_in);
        assert!(burned == shares_amount, errors::e_overflow());

        let base_out_amount = vault::instant_usdc_out(&plan);
        let base_out = coin::take(&mut v.treasury, base_out_amount, ctx);
        assert_vault_synced(v);
        (plan, option::some(base_out))
    } else {
        let request_id = vault::queued_request_id(&plan);
        let locked = coin::into_balance(shares_in);
        queue::lock_shares_for_new_request(q, request_id, locked);
        assert_vault_synced(v);
        (plan, option::none())
    }
}

public fun claim<BASE>(
    v: &mut Vault<BASE>,
    q: &mut queue::WithdrawalQueue,
    request_id: u64,
    _clock: &clock::Clock,
    ctx: &mut TxContext,
): coin::Coin<BASE> {
    let sender = tx_context::sender(ctx);
    let base_out_amount = vault::claim(&mut v.state, queue::state_mut(q), request_id, sender);

    let locked_shares = queue::take_locked_shares(q, request_id);
    let locked_coin = coin::from_balance(locked_shares, ctx);
    let burned = coin::burn(&mut v.sdye_treasury, locked_coin);
    assert!(burned > 0, errors::e_overflow());

    let base_out = coin::take(&mut v.treasury, base_out_amount, ctx);
    assert_vault_synced(v);
    base_out
}

public fun cycle<BASE>(
    v: &mut Vault<BASE>,
    q: &mut queue::WithdrawalQueue,
    cfg: &config::Config,
    spot_price: u64,
    clock: &clock::Clock,
    ctx: &mut TxContext,
): (u64, option::Option<coin::Coin<BASE>>) {
    assert_vault_synced(v);

    let needed = math::safe_add(
        queue::total_ready_usdc(queue::state(q)),
        queue::total_pending_usdc(queue::state(q)),
    );
    unwind_to_cover_liquidity(v, needed);

    let ts_ms = clock::timestamp_ms(clock);
    let (moved, bounty) = vault::cycle(
        &mut v.state,
        queue::state_mut(q),
        &mut v.oracle,
        spot_price,
        ts_ms,
        config::min_cycle_interval_ms(cfg),
        config::min_snapshot_interval_ms(cfg),
    );

    let bounty_opt = if (bounty > 0) {
        let bounty_coin = coin::take(&mut v.treasury, bounty, ctx);
        option::some(bounty_coin)
    } else {
        option::none()
    };

    rebalance_strategy_accounting(v, q, cfg, ts_ms);
    assert_vault_synced(v);
    (moved, bounty_opt)
}

#[test_only]
public fun deploy_for_testing<BASE>(v: &mut Vault<BASE>, amount: u64) {
    assert!(amount > 0, errors::e_zero_amount());
    assert_vault_synced(v);
    assert!(vault::treasury_usdc(&v.state) >= amount, errors::e_treasury_insufficient());

    move_treasury_to_balance(&mut v.treasury, &mut v.cetus_balance, amount);
    vault::set_treasury_usdc_for_testing(&mut v.state, balance::value(&v.treasury));
    v.cetus_deployed_usdc = balance::value(&v.cetus_balance);
    assert_vault_synced(v);
}
