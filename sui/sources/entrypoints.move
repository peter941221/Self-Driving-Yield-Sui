module self_driving_yield::entrypoints;

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
    sdye_treasury: coin::TreasuryCap<sdye::SDYE>,
}

fun assert_treasury_synced<BASE>(v: &Vault<BASE>) {
    assert!(vault::treasury_usdc(&v.state) == balance::value(&v.treasury), errors::e_overflow());
}

/// Initialize core shared objects:
/// - shared: `entrypoints::Vault<BASE>` + `queue::WithdrawalQueue`
/// - owned by sender: `config::Config` + `config::AdminCap`
public entry fun bootstrap<BASE>(
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
        sdye_treasury,
    };
    let q = queue::new_queue(ctx);

    transfer::share_object(v);
    transfer::public_share_object(q);
    transfer::public_transfer(cfg, tx_context::sender(ctx));
    transfer::public_transfer(cap, tx_context::sender(ctx));
}

/// Deposit base asset -> mint SDYE shares.
public entry fun deposit<BASE>(
    v: &mut Vault<BASE>,
    base_in: coin::Coin<BASE>,
    _clock: &clock::Clock,
    ctx: &mut TxContext,
): coin::Coin<sdye::SDYE> {
    let assets_in = coin::value(&base_in);
    coin::put(&mut v.treasury, base_in);

    let shares_out = vault::deposit(&mut v.state, assets_in);
    assert_treasury_synced(v);
    sdye::mint_shares(&mut v.sdye_treasury, shares_out, ctx)
}

/// Request a withdrawal by providing SDYE shares.
///
/// Returns (plan, base_out_opt). If plan is `Instant`, `base_out_opt` is `some(Coin<BASE>)`.
public entry fun request_withdraw<BASE>(
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
        assert_treasury_synced(v);
        (plan, option::some(base_out))
    } else {
        let request_id = vault::queued_request_id(&plan);
        let locked = coin::into_balance(shares_in);
        queue::lock_shares_for_new_request(q, request_id, locked);
        assert_treasury_synced(v);
        (plan, option::none())
    }
}

/// Claim a processed withdrawal request (Ready -> Claimed).
public entry fun claim<BASE>(
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
    assert_treasury_synced(v);
    base_out
}

/// Permissionless rebalance cycle. Returns (moved_ready_count, bounty_opt).
public entry fun cycle<BASE>(
    v: &mut Vault<BASE>,
    q: &mut queue::WithdrawalQueue,
    cfg: &config::Config,
    spot_price: u64,
    clock: &clock::Clock,
    ctx: &mut TxContext,
): (u64, option::Option<coin::Coin<BASE>>) {
    assert_treasury_synced(v);

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

    if (bounty > 0) {
        let bounty_coin = coin::take(&mut v.treasury, bounty, ctx);
        assert_treasury_synced(v);
        (moved, option::some(bounty_coin))
    } else {
        assert_treasury_synced(v);
        (moved, option::none())
    }
}

#[test_only]
public fun deploy_for_testing<BASE>(v: &mut Vault<BASE>, amount: u64) {
    assert!(amount > 0, errors::e_zero_amount());
    assert_treasury_synced(v);
    assert!(vault::treasury_usdc(&v.state) >= amount, errors::e_treasury_insufficient());

    let b = balance::split(&mut v.treasury, amount);
    balance::join(&mut v.deployed, b);
    let treasury = vault::treasury_usdc(&v.state);
    vault::set_treasury_usdc_for_testing(&mut v.state, math::safe_sub(treasury, amount));
    assert_treasury_synced(v);
}
