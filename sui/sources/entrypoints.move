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
use self_driving_yield::types;
use self_driving_yield::vault;
use self_driving_yield::yield_source;
use cetus_clmm::position::Position;
use sui::balance;
use sui::clock;
use sui::coin;
use sui::dynamic_object_field;
use sui::event;

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
    live_yield_address_slots: vector<address>,
    live_yield_metric_slots: vector<u64>,
    hedge_position_id: address,
    hedge_notional_usdc: u64,
    hedge_margin_usdc: u64,
    hedge_last_rebalance_ts_ms: u64,
    live_cetus_enabled: bool,
    live_cetus_position_present: bool,
    live_cetus_last_position_id: address,
    live_cetus_last_principal_a: u64,
    live_cetus_last_principal_b: u64,
    live_cetus_last_snapshot_ts_ms: u64,
    live_cetus_last_action_code: u64,
    last_rebalance_used_flash: bool,
    sdye_treasury: coin::TreasuryCap<sdye::SDYE>,
}

public struct DepositEvent has copy, drop, store {
    sender: address,
    assets_in: u64,
    shares_out: u64,
}

public struct WithdrawRequestedEvent has copy, drop, store {
    sender: address,
    request_id: u64,
    shares: u64,
    queued: bool,
    instant_assets_out: u64,
}

public struct ClaimedEvent has copy, drop, store {
    sender: address,
    request_id: u64,
    assets_out: u64,
}

public struct CycleEvent has copy, drop, store {
    spot_price: u64,
    moved_usdc: u64,
    bounty_usdc: u64,
    regime_code: u64,
    only_unwind: bool,
    safe_cycles_since_storm: u64,
    total_assets: u64,
    treasury_usdc: u64,
    deployed_usdc: u64,
    ready_usdc: u64,
    pending_usdc: u64,
    used_flash: bool,
}

public struct CetusPositionKey has copy, drop, store {}

fun cetus_position_key(): CetusPositionKey { CetusPositionKey {} }

const LIVE_CETUS_ACTION_NONE: u64 = 0;
const LIVE_CETUS_ACTION_OPEN: u64 = 1;
const LIVE_CETUS_ACTION_HOLD: u64 = 2;
const LIVE_CETUS_ACTION_CLOSE: u64 = 3;

const LIVE_YIELD_ACTION_NONE: u64 = 0;
const LIVE_YIELD_ADDRESS_MARKET_IDX: u64 = 0;
const LIVE_YIELD_ADDRESS_RECEIPT_IDX: u64 = 1;
const LIVE_YIELD_METRIC_ENABLED_IDX: u64 = 0;
const LIVE_YIELD_METRIC_PRESENT_IDX: u64 = 1;
const LIVE_YIELD_METRIC_PRINCIPAL_IDX: u64 = 2;
const LIVE_YIELD_METRIC_VALUE_IDX: u64 = 3;
const LIVE_YIELD_METRIC_SNAPSHOT_TS_IDX: u64 = 4;
const LIVE_YIELD_METRIC_ACTION_IDX: u64 = 5;

fun total_deployed_internal<BASE>(v: &Vault<BASE>): u64 {
    let cetus = balance::value(&v.cetus_balance);
    let y = balance::value(&v.yield_balance);
    let hedge = balance::value(&v.hedge_margin_balance);
    math::safe_add(math::safe_add(cetus, y), hedge)
}

fun regime_code(r: &types::Regime): u64 {
    if (vault::is_regime_calm(r)) {
        0
    } else if (vault::is_regime_normal(r)) {
        1
    } else {
        2
    }
}

fun sync_strategy_metadata<BASE>(v: &mut Vault<BASE>, cfg: &config::Config, ts_ms: u64) {
    let cetus = balance::value(&v.cetus_balance);
    v.cetus_deployed_usdc = cetus;
    v.cetus_last_rebalance_ts_ms = ts_ms;
    v.cetus_pool_id = if ((cetus > 0 || has_stored_cetus_position(v)) && cetus_amm::is_available(cfg)) { config::cetus_pool_id(cfg) } else { @0x0 };
    sync_cetus_live_presence(v, cfg);

    let y = balance::value(&v.yield_balance);
    v.yield_deployed_usdc = y;
    v.yield_last_rebalance_ts_ms = ts_ms;
    sync_yield_live_presence(v, cfg);
    let live_receipt_id = live_yield_address_slot(v, LIVE_YIELD_ADDRESS_RECEIPT_IDX);
    v.yield_receipt_id = if (live_receipt_id != @0x0) {
        live_receipt_id
    } else if (y > 0 && yield_source::is_available(cfg)) {
        config::lending_market_id(cfg)
    } else {
        @0x0
    };

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

fun bool_to_u64(v: bool): u64 {
    if (v) { 1 } else { 0 }
}

fun u64_to_bool(v: u64): bool { v != 0 }

fun set_live_yield_address_slot<BASE>(v: &mut Vault<BASE>, idx: u64, value: address) {
    *vector::borrow_mut(&mut v.live_yield_address_slots, idx) = value;
}

fun set_live_yield_metric_slot<BASE>(v: &mut Vault<BASE>, idx: u64, value: u64) {
    *vector::borrow_mut(&mut v.live_yield_metric_slots, idx) = value;
}

fun live_yield_address_slot<BASE>(v: &Vault<BASE>, idx: u64): address {
    *vector::borrow(&v.live_yield_address_slots, idx)
}

fun live_yield_metric_slot<BASE>(v: &Vault<BASE>, idx: u64): u64 {
    *vector::borrow(&v.live_yield_metric_slots, idx)
}

fun sync_cetus_live_presence<BASE>(v: &mut Vault<BASE>, cfg: &config::Config) {
    v.live_cetus_enabled = cetus_amm::is_available(cfg);
    v.live_cetus_position_present = has_stored_cetus_position(v);
    if (v.live_cetus_position_present) {
        v.live_cetus_last_position_id = stored_cetus_position_id(v);
    }
}

fun sync_yield_live_presence<BASE>(v: &mut Vault<BASE>, cfg: &config::Config) {
    let enabled = yield_source::is_available(cfg);
    set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_ENABLED_IDX, bool_to_u64(enabled));
    set_live_yield_address_slot(v, LIVE_YIELD_ADDRESS_MARKET_IDX, if (enabled) { config::lending_market_id(cfg) } else { @0x0 });
    let normalized_receipt = yield_source::normalize_live_receipt_id(
        cfg,
        live_yield_address_slot(v, LIVE_YIELD_ADDRESS_RECEIPT_IDX),
        live_yield_metric_slot(v, LIVE_YIELD_METRIC_VALUE_IDX),
    );
    set_live_yield_address_slot(v, LIVE_YIELD_ADDRESS_RECEIPT_IDX, normalized_receipt);
    let present = normalized_receipt != @0x0;
    set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_PRESENT_IDX, bool_to_u64(present));
    if (!present) {
        set_live_yield_address_slot(v, LIVE_YIELD_ADDRESS_RECEIPT_IDX, @0x0);
        if (live_yield_metric_slot(v, LIVE_YIELD_METRIC_VALUE_IDX) == 0) {
            set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_PRINCIPAL_IDX, 0);
            if (live_yield_metric_slot(v, LIVE_YIELD_METRIC_ACTION_IDX) == LIVE_YIELD_ACTION_NONE) {
                set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_SNAPSHOT_TS_IDX, 0);
            }
        }
    }
}

public(package) fun record_cetus_live_open<BASE>(
    v: &mut Vault<BASE>,
    cfg: &config::Config,
    position_id: address,
    principal_a: u64,
    principal_b: u64,
    ts_ms: u64,
) {
    sync_cetus_live_presence(v, cfg);
    v.live_cetus_enabled = true;
    v.live_cetus_position_present = true;
    v.live_cetus_last_position_id = position_id;
    v.live_cetus_last_principal_a = principal_a;
    v.live_cetus_last_principal_b = principal_b;
    v.live_cetus_last_snapshot_ts_ms = ts_ms;
    v.live_cetus_last_action_code = LIVE_CETUS_ACTION_OPEN;
}

public(package) fun record_cetus_live_hold<BASE>(v: &mut Vault<BASE>, cfg: &config::Config, ts_ms: u64) {
    sync_cetus_live_presence(v, cfg);
    if (v.live_cetus_position_present) {
        v.live_cetus_last_snapshot_ts_ms = ts_ms;
        v.live_cetus_last_action_code = LIVE_CETUS_ACTION_HOLD;
    }
}

public(package) fun record_cetus_live_snapshot<BASE>(
    v: &mut Vault<BASE>,
    cfg: &config::Config,
    position_id: address,
    amount_a: u64,
    amount_b: u64,
    ts_ms: u64,
) {
    sync_cetus_live_presence(v, cfg);
    v.live_cetus_enabled = cetus_amm::is_available(cfg);
    v.live_cetus_position_present = true;
    v.live_cetus_last_position_id = position_id;
    v.live_cetus_last_principal_a = amount_a;
    v.live_cetus_last_principal_b = amount_b;
    v.live_cetus_last_snapshot_ts_ms = ts_ms;
    v.live_cetus_last_action_code = LIVE_CETUS_ACTION_HOLD;
}

public(package) fun record_cetus_live_close<BASE>(
    v: &mut Vault<BASE>,
    cfg: &config::Config,
    position_id: address,
    ts_ms: u64,
) {
    sync_cetus_live_presence(v, cfg);
    v.live_cetus_enabled = cetus_amm::is_available(cfg);
    v.live_cetus_position_present = false;
    v.live_cetus_last_position_id = position_id;
    v.live_cetus_last_principal_a = 0;
    v.live_cetus_last_principal_b = 0;
    v.live_cetus_last_snapshot_ts_ms = ts_ms;
    v.live_cetus_last_action_code = LIVE_CETUS_ACTION_CLOSE;
}

public(package) fun record_live_yield_deposit<BASE>(
    v: &mut Vault<BASE>,
    cfg: &config::Config,
    receipt_id: address,
    deposited_value: u64,
    current_value: u64,
    ts_ms: u64,
) {
    sync_yield_live_presence(v, cfg);
    let enabled = yield_source::is_available(cfg);
    let next_receipt = yield_source::normalize_live_receipt_id(cfg, receipt_id, current_value);
    let next_principal = yield_source::principal_after_live_deposit(live_yield_metric_slot(v, LIVE_YIELD_METRIC_PRINCIPAL_IDX), deposited_value);
    set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_ENABLED_IDX, bool_to_u64(enabled));
    set_live_yield_address_slot(v, LIVE_YIELD_ADDRESS_MARKET_IDX, if (enabled) { config::lending_market_id(cfg) } else { @0x0 });
    set_live_yield_address_slot(v, LIVE_YIELD_ADDRESS_RECEIPT_IDX, next_receipt);
    set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_PRESENT_IDX, bool_to_u64(next_receipt != @0x0));
    set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_PRINCIPAL_IDX, next_principal);
    set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_VALUE_IDX, current_value);
    set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_SNAPSHOT_TS_IDX, ts_ms);
    set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_ACTION_IDX, yield_source::live_yield_action_deposit());
    v.yield_receipt_id = next_receipt;
    v.yield_last_rebalance_ts_ms = ts_ms;
}

public(package) fun record_live_yield_hold<BASE>(
    v: &mut Vault<BASE>,
    cfg: &config::Config,
    receipt_id: address,
    current_value: u64,
    ts_ms: u64,
) {
    sync_yield_live_presence(v, cfg);
    let enabled = yield_source::is_available(cfg);
    let next_receipt = yield_source::normalize_live_receipt_id(cfg, receipt_id, current_value);
    let present = next_receipt != @0x0;
    set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_ENABLED_IDX, bool_to_u64(enabled));
    set_live_yield_address_slot(v, LIVE_YIELD_ADDRESS_MARKET_IDX, if (enabled) { config::lending_market_id(cfg) } else { @0x0 });
    set_live_yield_address_slot(v, LIVE_YIELD_ADDRESS_RECEIPT_IDX, next_receipt);
    set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_PRESENT_IDX, bool_to_u64(present));
    set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_VALUE_IDX, current_value);
    set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_SNAPSHOT_TS_IDX, ts_ms);
    set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_ACTION_IDX, if (present) { yield_source::live_yield_action_hold() } else { LIVE_YIELD_ACTION_NONE });
    v.yield_receipt_id = next_receipt;
    v.yield_last_rebalance_ts_ms = ts_ms;
}

public(package) fun record_live_yield_withdraw<BASE>(
    v: &mut Vault<BASE>,
    cfg: &config::Config,
    receipt_id: address,
    withdrawn_value: u64,
    remaining_value: u64,
    ts_ms: u64,
) {
    let next_principal = yield_source::principal_after_live_withdraw(
        live_yield_metric_slot(v, LIVE_YIELD_METRIC_PRINCIPAL_IDX),
        live_yield_metric_slot(v, LIVE_YIELD_METRIC_VALUE_IDX),
        withdrawn_value,
    );
    sync_yield_live_presence(v, cfg);
    let enabled = yield_source::is_available(cfg);
    let next_receipt = yield_source::normalize_live_receipt_id(cfg, receipt_id, remaining_value);
    set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_ENABLED_IDX, bool_to_u64(enabled));
    set_live_yield_address_slot(v, LIVE_YIELD_ADDRESS_MARKET_IDX, if (enabled) { config::lending_market_id(cfg) } else { @0x0 });
    set_live_yield_address_slot(v, LIVE_YIELD_ADDRESS_RECEIPT_IDX, next_receipt);
    set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_PRESENT_IDX, bool_to_u64(next_receipt != @0x0));
    set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_PRINCIPAL_IDX, next_principal);
    set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_VALUE_IDX, remaining_value);
    set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_SNAPSHOT_TS_IDX, ts_ms);
    set_live_yield_metric_slot(v, LIVE_YIELD_METRIC_ACTION_IDX, if (remaining_value == 0) {
        yield_source::live_yield_action_withdraw_full()
    } else {
        yield_source::live_yield_action_withdraw_partial()
    });
    v.yield_receipt_id = next_receipt;
    v.yield_last_rebalance_ts_ms = ts_ms;
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
    let adjusted_buffer_bps = types::adjusted_buffer_bps(buffer_bps, total_assets, queued_need);
    let buffer_target = math::mul_div(total_assets, adjusted_buffer_bps, 10000);
    let reserved_liquidity = if (buffer_target > queued_need) { buffer_target } else { queued_need };
    let max_deployable = if (total_assets > reserved_liquidity) { total_assets - reserved_liquidity } else { 0 };
    let lp_nominal = if (cetus_amm::is_available(cfg)) { math::mul_div(total_assets, lp_bps, 10000) } else { 0 };
    let lp_capacity = if (perp_hedge::is_available(cfg) && lp_nominal > 0) {
        math::mul_div(max_deployable, 10000, 10000 + perp_hedge::initial_margin_bps())
    } else {
        max_deployable
    };
    let target_lp = if (lp_nominal < lp_capacity) { lp_nominal } else { lp_capacity };
    let hedge_margin_target = if (perp_hedge::is_available(cfg) && target_lp > 0) { perp_hedge::required_margin(target_lp) } else { 0 };

    let yield_nominal = if (yield_source::is_available(cfg)) { math::mul_div(total_assets, yield_bps, 10000) } else { 0 };
    let deployable_after_hedge = if (max_deployable > hedge_margin_target) { max_deployable - hedge_margin_target } else { 0 };
    let remaining_after_lp = if (deployable_after_hedge > target_lp) { deployable_after_hedge - target_lp } else { 0 };
    let target_yield = if (yield_nominal < remaining_after_lp) { yield_nominal } else { remaining_after_lp };

    (target_lp, target_yield, hedge_margin_target)
}

fun rebalance_strategy_accounting<BASE>(
    v: &mut Vault<BASE>,
    q: &queue::WithdrawalQueue,
    cfg: &config::Config,
    ts_ms: u64,
) {
    if (has_stored_cetus_position(v)) {
        v.last_rebalance_used_flash = false;
        record_cetus_live_hold(v, cfg, ts_ms);
        sync_strategy_metadata(v, cfg, ts_ms);
        return
    };

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
public fun has_stored_cetus_position<BASE>(v: &Vault<BASE>): bool {
    dynamic_object_field::exists_(&v.id, cetus_position_key())
}

public fun stored_cetus_position_id<BASE>(v: &Vault<BASE>): address {
    assert!(has_stored_cetus_position(v), errors::e_missing_object());
    let position_nft = dynamic_object_field::borrow<CetusPositionKey, Position>(&v.id, cetus_position_key());
    let position_id = object::id(position_nft);
    object::id_to_address(&position_id)
}

public(package) fun borrow_stored_cetus_position<BASE>(v: &Vault<BASE>): &Position {
    assert!(has_stored_cetus_position(v), errors::e_missing_object());
    dynamic_object_field::borrow<CetusPositionKey, Position>(&v.id, cetus_position_key())
}

public fun store_cetus_position<BASE>(v: &mut Vault<BASE>, position_nft: Position) {
    assert!(!has_stored_cetus_position(v), errors::e_invalid_plan());
    dynamic_object_field::add(&mut v.id, cetus_position_key(), position_nft);
}

public fun take_cetus_position<BASE>(v: &mut Vault<BASE>): Position {
    assert!(has_stored_cetus_position(v), errors::e_missing_object());
    dynamic_object_field::remove<CetusPositionKey, Position>(&mut v.id, cetus_position_key())
}

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
public fun live_yield_enabled<BASE>(v: &Vault<BASE>): bool { u64_to_bool(live_yield_metric_slot(v, LIVE_YIELD_METRIC_ENABLED_IDX)) }
public fun live_yield_position_present<BASE>(v: &Vault<BASE>): bool { u64_to_bool(live_yield_metric_slot(v, LIVE_YIELD_METRIC_PRESENT_IDX)) }
public fun live_yield_last_market_id<BASE>(v: &Vault<BASE>): address { live_yield_address_slot(v, LIVE_YIELD_ADDRESS_MARKET_IDX) }
public fun live_yield_last_receipt_id<BASE>(v: &Vault<BASE>): address { live_yield_address_slot(v, LIVE_YIELD_ADDRESS_RECEIPT_IDX) }
public fun live_yield_last_principal<BASE>(v: &Vault<BASE>): u64 { live_yield_metric_slot(v, LIVE_YIELD_METRIC_PRINCIPAL_IDX) }
public fun live_yield_last_value<BASE>(v: &Vault<BASE>): u64 { live_yield_metric_slot(v, LIVE_YIELD_METRIC_VALUE_IDX) }
public fun live_yield_last_snapshot_ts_ms<BASE>(v: &Vault<BASE>): u64 { live_yield_metric_slot(v, LIVE_YIELD_METRIC_SNAPSHOT_TS_IDX) }
public fun live_yield_last_action_code<BASE>(v: &Vault<BASE>): u64 { live_yield_metric_slot(v, LIVE_YIELD_METRIC_ACTION_IDX) }
public fun hedge_position_id<BASE>(v: &Vault<BASE>): address { v.hedge_position_id }
public fun hedge_notional_usdc<BASE>(v: &Vault<BASE>): u64 { v.hedge_notional_usdc }
public fun hedge_margin_usdc<BASE>(v: &Vault<BASE>): u64 { v.hedge_margin_usdc }
public fun live_cetus_enabled<BASE>(v: &Vault<BASE>): bool { v.live_cetus_enabled }
public fun live_cetus_position_present<BASE>(v: &Vault<BASE>): bool { v.live_cetus_position_present }
public fun live_cetus_last_position_id<BASE>(v: &Vault<BASE>): address { v.live_cetus_last_position_id }
public fun live_cetus_last_principal_a<BASE>(v: &Vault<BASE>): u64 { v.live_cetus_last_principal_a }
public fun live_cetus_last_principal_b<BASE>(v: &Vault<BASE>): u64 { v.live_cetus_last_principal_b }
public fun live_cetus_last_snapshot_ts_ms<BASE>(v: &Vault<BASE>): u64 { v.live_cetus_last_snapshot_ts_ms }
public fun live_cetus_last_action_code<BASE>(v: &Vault<BASE>): u64 { v.live_cetus_last_action_code }
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
        live_yield_address_slots: vector[@0x0, @0x0],
        live_yield_metric_slots: vector[0, 0, 0, 0, 0, LIVE_YIELD_ACTION_NONE],
        hedge_position_id: @0x0,
        hedge_notional_usdc: 0,
        hedge_margin_usdc: 0,
        hedge_last_rebalance_ts_ms: 0,
        live_cetus_enabled: false,
        live_cetus_position_present: false,
        live_cetus_last_position_id: @0x0,
        live_cetus_last_principal_a: 0,
        live_cetus_last_principal_b: 0,
        live_cetus_last_snapshot_ts_ms: 0,
        live_cetus_last_action_code: LIVE_CETUS_ACTION_NONE,
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
    let sender = tx_context::sender(ctx);
    let assets_in = coin::value(&base_in);
    coin::put(&mut v.treasury, base_in);

    let shares_out = vault::deposit(&mut v.state, assets_in);
    assert_vault_synced(v);
    event::emit(DepositEvent { sender, assets_in, shares_out });
    sdye::mint_shares(&mut v.sdye_treasury, shares_out, ctx)
}

public fun deposit_entry<BASE>(
    v: &mut Vault<BASE>,
    base_in: coin::Coin<BASE>,
    clock: &clock::Clock,
    ctx: &mut TxContext,
) {
    let shares = deposit(v, base_in, clock, ctx);
    transfer::public_transfer(shares, tx_context::sender(ctx));
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
        event::emit(WithdrawRequestedEvent {
            sender,
            request_id: 0,
            shares: shares_amount,
            queued: false,
            instant_assets_out: base_out_amount,
        });
        (plan, option::some(base_out))
    } else {
        let request_id = vault::queued_request_id(&plan);
        let locked = coin::into_balance(shares_in);
        queue::lock_shares_for_new_request(q, request_id, locked);
        assert_vault_synced(v);
        event::emit(WithdrawRequestedEvent {
            sender,
            request_id,
            shares: shares_amount,
            queued: true,
            instant_assets_out: 0,
        });
        (plan, option::none())
    }
}

public fun request_withdraw_entry<BASE>(
    v: &mut Vault<BASE>,
    q: &mut queue::WithdrawalQueue,
    shares_in: coin::Coin<sdye::SDYE>,
    clock: &clock::Clock,
    ctx: &mut TxContext,
) {
    let (_, base_opt) = request_withdraw(v, q, shares_in, clock, ctx);
    if (option::is_some(&base_opt)) {
        let base_out = option::destroy_some(base_opt);
        transfer::public_transfer(base_out, tx_context::sender(ctx));
    } else {
        option::destroy_none(base_opt);
    };
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
    event::emit(ClaimedEvent { sender, request_id, assets_out: base_out_amount });
    base_out
}

public fun claim_entry<BASE>(
    v: &mut Vault<BASE>,
    q: &mut queue::WithdrawalQueue,
    request_id: u64,
    clock: &clock::Clock,
    ctx: &mut TxContext,
) {
    let base_out = claim(v, q, request_id, clock, ctx);
    transfer::public_transfer(base_out, tx_context::sender(ctx));
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

    let regime = oracle::current_regime(&v.oracle);
    let risk_mode = vault::risk_mode(&v.state);
    let ready_usdc = queue::total_ready_usdc(queue::state(q));
    let pending_usdc = queue::total_pending_usdc(queue::state(q));
    event::emit(CycleEvent {
        spot_price,
        moved_usdc: moved,
        bounty_usdc: bounty,
        regime_code: regime_code(&regime),
        only_unwind: vault::is_only_unwind(&risk_mode),
        safe_cycles_since_storm: vault::safe_cycles_since_storm(&v.state),
        total_assets: vault::total_assets(&v.state),
        treasury_usdc: vault::treasury_usdc(&v.state),
        deployed_usdc: total_deployed_internal(v),
        ready_usdc,
        pending_usdc,
        used_flash: v.last_rebalance_used_flash,
    });
    (moved, bounty_opt)
}

public fun cycle_entry<BASE>(
    v: &mut Vault<BASE>,
    q: &mut queue::WithdrawalQueue,
    cfg: &config::Config,
    spot_price: u64,
    clock: &clock::Clock,
    ctx: &mut TxContext,
) {
    let (_, bounty_opt) = cycle(v, q, cfg, spot_price, clock, ctx);
    if (option::is_some(&bounty_opt)) {
        let bounty = option::destroy_some(bounty_opt);
        transfer::public_transfer(bounty, tx_context::sender(ctx));
    } else {
        option::destroy_none(bounty_opt);
    };
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
