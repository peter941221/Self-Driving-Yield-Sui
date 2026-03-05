module self_driving_yield::vault;

use self_driving_yield::errors;
use self_driving_yield::math;
use self_driving_yield::oracle;
use self_driving_yield::queue;
use self_driving_yield::types;

const MAX_BOUNTY_BPS: u64 = 5;

public fun max_bounty_bps(): u64 { MAX_BOUNTY_BPS }

public fun regime_calm(): types::Regime { types::regime_calm() }
public fun regime_normal(): types::Regime { types::regime_normal() }
public fun regime_storm(): types::Regime { types::regime_storm() }

public fun is_regime_calm(r: &types::Regime): bool { types::is_regime_calm(r) }
public fun is_regime_normal(r: &types::Regime): bool { types::is_regime_normal(r) }
public fun is_regime_storm(r: &types::Regime): bool { types::is_regime_storm(r) }

public fun risk_normal(): types::RiskMode { types::risk_normal() }
public fun risk_only_unwind(): types::RiskMode { types::risk_only_unwind() }
public fun is_only_unwind(m: &types::RiskMode): bool { types::is_only_unwind(m) }

/// Allocation in basis points: (yield, lp, buffer).
public fun get_allocation(regime: &types::Regime): (u64, u64, u64) { types::get_allocation(regime) }

/// First deposit: shares=assets (1:1). Otherwise: floor(assets * total_shares / total_assets).
public fun calc_shares_to_mint(assets_in: u64, total_assets: u64, total_shares: u64): u64 {
    assert!(assets_in > 0, errors::e_zero_amount());
    if (total_assets == 0 || total_shares == 0) {
        assets_in
    } else {
        math::mul_div(assets_in, total_shares, total_assets)
    }
}

/// floor(shares * total_assets / total_shares)
public fun calc_usdc_to_redeem(shares_in: u64, total_assets: u64, total_shares: u64): u64 {
    assert!(shares_in > 0, errors::e_zero_amount());
    math::mul_div(shares_in, total_assets, total_shares)
}

public struct VaultState has store, drop {
    total_assets: u64,
    total_shares: u64,
    treasury_usdc: u64,
    risk_mode: types::RiskMode,
    last_cycle_ts_ms: u64,
}

public fun new_state(): VaultState {
    VaultState {
        total_assets: 0,
        total_shares: 0,
        treasury_usdc: 0,
        risk_mode: types::risk_normal(),
        last_cycle_ts_ms: 0,
    }
}

public fun total_assets(s: &VaultState): u64 { s.total_assets }
public fun total_shares(s: &VaultState): u64 { s.total_shares }
public fun treasury_usdc(s: &VaultState): u64 { s.treasury_usdc }
public fun risk_mode(s: &VaultState): types::RiskMode { s.risk_mode }
public fun last_cycle_ts_ms(s: &VaultState): u64 { s.last_cycle_ts_ms }

public fun set_risk_mode(s: &mut VaultState, m: types::RiskMode) { s.risk_mode = m }

public(package) fun set_treasury_usdc_for_testing(s: &mut VaultState, v: u64) {
    s.treasury_usdc = v;
}

/// deposit(assets) -> shares_out
/// Effects (pure accounting): treasury += assets, totals += assets/shares.
public fun deposit(s: &mut VaultState, assets_in: u64): u64 {
    assert!(!is_only_unwind(&s.risk_mode), errors::e_only_unwind());

    let shares_out = calc_shares_to_mint(assets_in, s.total_assets, s.total_shares);
    assert!(shares_out > 0, errors::e_zero_shares());

    s.treasury_usdc = math::safe_add(s.treasury_usdc, assets_in);
    s.total_assets = math::safe_add(s.total_assets, assets_in);
    s.total_shares = math::safe_add(s.total_shares, shares_out);
    shares_out
}

/// cycle() — Core 7-phase state machine (P1: adapters mocked).
/// Returns (moved_ready, bounty_usdc).
public fun cycle(
    s: &mut VaultState,
    q: &mut queue::QueueState,
    o: &mut oracle::OracleState,
    spot_price: u64,
    ts_ms: u64,
    min_cycle_interval_ms: u64,
    min_snapshot_interval_ms: u64,
): (u64, u64) {
    // Phase 0: pre-checks (interval gate).
    if (s.last_cycle_ts_ms != 0) {
        assert!(
            ts_ms >= s.last_cycle_ts_ms + min_cycle_interval_ms,
            errors::e_cycle_too_early(),
        );
    };

    // Phase 2: record snapshot and infer regime.
    let _ = oracle::record_snapshot_with_ts(o, spot_price, ts_ms, min_snapshot_interval_ms);
    let regime = oracle::current_regime(o);

    // Phase 4: minimal risk control (storm => OnlyUnwind).
    if (types::is_regime_storm(&regime)) {
        s.risk_mode = types::risk_only_unwind();
    } else {
        s.risk_mode = types::risk_normal();
    };

    // Phase 6: process withdrawal queue, reserving ready balances.
    let reserved_ready = queue::total_ready_usdc(q);
    assert!(s.treasury_usdc >= reserved_ready, errors::e_overflow());
    let mut remaining = s.treasury_usdc - reserved_ready;
    let moved = queue::process_queue(q, &mut remaining);

    // Phase 7: bounded bounty (<= max_bounty_bps * total_assets), paid from remaining.
    let max_bounty = math::mul_div(s.total_assets, MAX_BOUNTY_BPS, 10000);
    let bounty = if (remaining < max_bounty) { remaining } else { max_bounty };
    if (bounty > 0) {
        s.treasury_usdc = math::safe_sub(s.treasury_usdc, bounty);
        s.total_assets = math::safe_sub(s.total_assets, bounty);
    };

    s.last_cycle_ts_ms = ts_ms;
    (moved, bounty)
}

public enum WithdrawPlan has copy, drop, store {
    Instant { usdc_out: u64 },
    Queued { request_id: u64, usdc_amount: u64 },
}

public fun plan_is_instant(p: &WithdrawPlan): bool {
    match (p) {
        WithdrawPlan::Instant { usdc_out: _ } => true,
        _ => false,
    }
}

public fun plan_is_queued(p: &WithdrawPlan): bool {
    match (p) {
        WithdrawPlan::Queued { request_id: _, usdc_amount: _ } => true,
        _ => false,
    }
}

public fun instant_usdc_out(p: &WithdrawPlan): u64 {
    match (p) {
        WithdrawPlan::Instant { usdc_out } => *usdc_out,
        _ => abort errors::e_invalid_plan(),
    }
}

public fun queued_request_id(p: &WithdrawPlan): u64 {
    match (p) {
        WithdrawPlan::Queued { request_id, usdc_amount: _ } => *request_id,
        _ => abort errors::e_invalid_plan(),
    }
}

public fun queued_usdc_amount(p: &WithdrawPlan): u64 {
    match (p) {
        WithdrawPlan::Queued { request_id: _, usdc_amount } => *usdc_amount,
        _ => abort errors::e_invalid_plan(),
    }
}

/// request_withdraw(shares) -> instant redeem if treasury can cover, else enqueue.
/// Note: this is the *accounting* core; adapter unwinds and claim() are handled later.
public fun request_withdraw(
    s: &mut VaultState,
    q: &mut queue::QueueState,
    owner: address,
    shares_in: u64,
    created_at_ms: u64,
): WithdrawPlan {
    assert!(shares_in > 0, errors::e_zero_amount());
    assert!(s.total_shares >= shares_in, errors::e_insufficient_shares());

    let usdc_amount = calc_usdc_to_redeem(shares_in, s.total_assets, s.total_shares);
    assert!(usdc_amount > 0, errors::e_zero_usdc_out());

    if (s.treasury_usdc >= usdc_amount) {
        s.treasury_usdc = math::safe_sub(s.treasury_usdc, usdc_amount);
        s.total_assets = math::safe_sub(s.total_assets, usdc_amount);
        s.total_shares = math::safe_sub(s.total_shares, shares_in);
        WithdrawPlan::Instant { usdc_out: usdc_amount }
    } else {
        let request_id = queue::enqueue(q, owner, shares_in, usdc_amount, created_at_ms);
        WithdrawPlan::Queued { request_id, usdc_amount }
    }
}

/// claim(request_id) -> usdc_out
/// Requires request Ready and sender == owner.
public fun claim(
    s: &mut VaultState,
    q: &mut queue::QueueState,
    request_id: u64,
    sender: address,
): u64 {
    let (st, owner, usdc_out, locked_shares) = {
        let req = queue::borrow_request(q, request_id);
        (
            queue::status(req),
            queue::owner(req),
            queue::usdc_amount(req),
            queue::shares(req),
        )
    };
    assert!(queue::is_ready(&st), errors::e_request_not_ready());

    assert!(owner == sender, errors::e_not_owner());

    assert!(usdc_out > 0, errors::e_zero_usdc_out());
    assert!(s.treasury_usdc >= usdc_out, errors::e_treasury_insufficient());
    assert!(s.total_assets >= usdc_out, errors::e_overflow());
    assert!(s.total_shares >= locked_shares, errors::e_insufficient_shares());

    s.treasury_usdc = math::safe_sub(s.treasury_usdc, usdc_out);
    s.total_assets = math::safe_sub(s.total_assets, usdc_out);
    s.total_shares = math::safe_sub(s.total_shares, locked_shares);
    queue::claim_ready(q, request_id);
    usdc_out
}
