module self_driving_yield::entrypoints;

use self_driving_yield::cetus_amm;
use self_driving_yield::config;
use self_driving_yield::errors;
use self_driving_yield::math;
use self_driving_yield::oracle;
use self_driving_yield::queue;
use self_driving_yield::sdye;
use self_driving_yield::vault;
use sui::balance;
use sui::clock;
use sui::coin;

/// Shared vault object holding balances + pure accounting state.
///
/// Type parameter `BASE` is the base asset (e.g. native USDC on mainnet).
public struct Vault<phantom BASE> has key, store {
    id: UID,
    state: vault::VaultState,
    oracle: oracle::OracleState,
    treasury: balance::Balance<BASE>,
    deployed: balance::Balance<BASE>,
    cetus_pool_id: address,
    cetus_deployed_usdc: u64,
    cetus_last_rebalance_ts_ms: u64,
    sdye_treasury: coin::TreasuryCap<sdye::SDYE>,
}

fun assert_vault_synced<BASE>(v: &Vault<BASE>) {
    let treasury = balance::value(&v.treasury);
    let deployed = balance::value(&v.deployed);
    assert!(vault::treasury_usdc(&v.state) == treasury, errors::e_overflow());
    assert!(v.cetus_deployed_usdc == deployed, errors::e_overflow());
    assert!(vault::total_assets(&v.state) == math::safe_add(treasury, deployed), errors::e_overflow());
}

fun sync_cetus_position_state<BASE>(
    v: &mut Vault<BASE>,
    cfg: &config::Config,
    ts_ms: u64,
) {
    let deployed = balance::value(&v.deployed);
    v.cetus_deployed_usdc = deployed;
    v.cetus_last_rebalance_ts_ms = ts_ms;
    if (deployed > 0) {
        v.cetus_pool_id = config::cetus_pool_id(cfg);
    } else {
        v.cetus_pool_id = @0x0;
    }
}

fun sync_deployed_amount_only<BASE>(v: &mut Vault<BASE>, ts_ms: u64) {
    let deployed = balance::value(&v.deployed);
    v.cetus_deployed_usdc = deployed;
    v.cetus_last_rebalance_ts_ms = ts_ms;
    if (deployed == 0) {
        v.cetus_pool_id = @0x0;
    }
}

fun target_cetus_deployed_usdc<BASE>(
    v: &Vault<BASE>,
    q: &queue::WithdrawalQueue,
    cfg: &config::Config,
): u64 {
    if (!cetus_amm::is_available(cfg) || vault::is_only_unwind(&vault::risk_mode(&v.state))) {
        0
    } else {
        let regime = oracle::current_regime(&v.oracle);
        let (_, lp_bps, _) = vault::get_allocation(&regime);
        let total_assets = vault::total_assets(&v.state);
        let target_lp = math::mul_div(total_assets, lp_bps, 10000);
        let required_liquidity = math::safe_add(
            queue::total_ready_usdc(queue::state(q)),
            queue::total_pending_usdc(queue::state(q)),
        );
        let max_deployable = if (total_assets > required_liquidity) {
            total_assets - required_liquidity
        } else {
            0
        };
        if (target_lp < max_deployable) { target_lp } else { max_deployable }
    }
}

fun rebalance_cetus_accounting<BASE>(
    v: &mut Vault<BASE>,
    q: &queue::WithdrawalQueue,
    cfg: &config::Config,
    ts_ms: u64,
) {
    if (!cetus_amm::is_available(cfg)) {
        sync_deployed_amount_only(v, ts_ms);
        return
    };

    let current_deployed = balance::value(&v.deployed);
    let target_deployed = target_cetus_deployed_usdc(v, q, cfg);
    let treasury = vault::treasury_usdc(&v.state);

    if (current_deployed < target_deployed) {
        let delta = target_deployed - current_deployed;
        let moved = balance::split(&mut v.treasury, delta);
        balance::join(&mut v.deployed, moved);
        vault::set_treasury_usdc_for_testing(&mut v.state, math::safe_sub(treasury, delta));
    } else if (current_deployed > target_deployed) {
        let delta = current_deployed - target_deployed;
        let moved = balance::split(&mut v.deployed, delta);
        balance::join(&mut v.treasury, moved);
        vault::set_treasury_usdc_for_testing(&mut v.state, math::safe_add(treasury, delta));
    };

    sync_cetus_position_state(v, cfg, ts_ms);
}

public fun has_cetus_position<BASE>(v: &Vault<BASE>): bool { v.cetus_deployed_usdc > 0 }
public fun cetus_pool_id<BASE>(v: &Vault<BASE>): address { v.cetus_pool_id }
public fun cetus_deployed_usdc<BASE>(v: &Vault<BASE>): u64 { v.cetus_deployed_usdc }
public fun cetus_last_rebalance_ts_ms<BASE>(v: &Vault<BASE>): u64 { v.cetus_last_rebalance_ts_ms }
public fun deployed_balance<BASE>(v: &Vault<BASE>): u64 { balance::value(&v.deployed) }

/// Initialize core shared objects:
/// - shared: `entrypoints::Vault<BASE>` + `queue::WithdrawalQueue` + `config::Config`
/// - owned by sender: `config::AdminCap`
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
        deployed: balance::zero(),
        cetus_pool_id: @0x0,
        cetus_deployed_usdc: 0,
        cetus_last_rebalance_ts_ms: 0,
        sdye_treasury,
    };
    let q = queue::new_queue(ctx);

    transfer::share_object(v);
    transfer::public_share_object(q);
    transfer::public_share_object(cfg);
    transfer::public_transfer(cap, tx_context::sender(ctx));
}

/// Deposit base asset -> mint SDYE shares.
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

/// Request a withdrawal by providing SDYE shares.
///
/// Returns (plan, base_out_opt). If plan is `Instant`, `base_out_opt` is `some(Coin<BASE>)`.
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

/// Claim a processed withdrawal request (Ready -> Claimed).
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

/// Permissionless rebalance cycle. Returns (moved_ready_count, bounty_opt).
public fun cycle<BASE>(
    v: &mut Vault<BASE>,
    q: &mut queue::WithdrawalQueue,
    cfg: &config::Config,
    spot_price: u64,
    clock: &clock::Clock,
    ctx: &mut TxContext,
): (u64, option::Option<coin::Coin<BASE>>) {
    assert_vault_synced(v);

    // Minimal unwind simulation: move from deployed -> treasury to cover (ready + pending) requests.
    let needed = math::safe_add(
        queue::total_ready_usdc(queue::state(q)),
        queue::total_pending_usdc(queue::state(q)),
    );
    if (vault::treasury_usdc(&v.state) < needed) {
        let treasury = vault::treasury_usdc(&v.state);
        let deficit = needed - treasury;
        let deployed_value = balance::value(&v.deployed);
        let unwind = if (deployed_value < deficit) { deployed_value } else { deficit };
        if (unwind > 0) {
            let b = balance::split(&mut v.deployed, unwind);
            balance::join(&mut v.treasury, b);
            let new_treasury = math::safe_add(treasury, unwind);
            vault::set_treasury_usdc_for_testing(&mut v.state, new_treasury);
        }
    };

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

    rebalance_cetus_accounting(v, q, cfg, ts_ms);
    assert_vault_synced(v);
    (moved, bounty_opt)
}

#[test_only]
public fun deploy_for_testing<BASE>(v: &mut Vault<BASE>, amount: u64) {
    assert!(amount > 0, errors::e_zero_amount());
    assert_vault_synced(v);
    assert!(vault::treasury_usdc(&v.state) >= amount, errors::e_treasury_insufficient());

    let b = balance::split(&mut v.treasury, amount);
    balance::join(&mut v.deployed, b);
    let treasury = vault::treasury_usdc(&v.state);
    vault::set_treasury_usdc_for_testing(&mut v.state, math::safe_sub(treasury, amount));
    v.cetus_deployed_usdc = balance::value(&v.deployed);
    assert_vault_synced(v);
}
