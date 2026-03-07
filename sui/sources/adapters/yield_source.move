module self_driving_yield::yield_source;

use self_driving_yield::config;
use self_driving_yield::math;

const MOCK_YIELD_BPS_PER_CYCLE: u64 = 2;
const LIVE_YIELD_ACTION_NONE: u64 = 0;
const LIVE_YIELD_ACTION_DEPOSIT: u64 = 1;
const LIVE_YIELD_ACTION_HOLD: u64 = 2;
const LIVE_YIELD_ACTION_WITHDRAW_PARTIAL: u64 = 3;
const LIVE_YIELD_ACTION_WITHDRAW_FULL: u64 = 4;

/// Returns true when a lending market id is configured (P2).
public fun is_available(cfg: &config::Config): bool {
    config::lending_market_id(cfg) != @0x0
}

public fun live_yield_action_none(): u64 { LIVE_YIELD_ACTION_NONE }
public fun live_yield_action_deposit(): u64 { LIVE_YIELD_ACTION_DEPOSIT }
public fun live_yield_action_hold(): u64 { LIVE_YIELD_ACTION_HOLD }
public fun live_yield_action_withdraw_partial(): u64 { LIVE_YIELD_ACTION_WITHDRAW_PARTIAL }
public fun live_yield_action_withdraw_full(): u64 { LIVE_YIELD_ACTION_WITHDRAW_FULL }

/// Accounting helper for LST staking paths used by the vault planner.
/// In this repo snapshot, we conservatively model 1:1 principal conversion.
public fun stake_sui_for_lst(_cfg: &config::Config, sui_amount: u64): u64 {
    sui_amount
}

/// Accounting helper for LST unstake paths used by the vault planner.
/// In this repo snapshot, we conservatively model 1:1 principal conversion.
public fun unstake_lst(_cfg: &config::Config, lst_amount: u64): u64 {
    lst_amount
}

/// Create or refresh a lending receipt for a deployed base-asset amount.
public fun deposit_to_lending(cfg: &config::Config, amount: u64): address {
    if (!is_available(cfg) || amount == 0) { @0x0 } else { config::lending_market_id(cfg) }
}

public fun normalize_live_receipt_id(cfg: &config::Config, receipt_id: address, tracked_value: u64): address {
    if (!is_available(cfg) || receipt_id == @0x0 || tracked_value == 0) {
        @0x0
    } else {
        receipt_id
    }
}

public fun principal_after_live_deposit(current_principal: u64, deposited_value: u64): u64 {
    math::safe_add(current_principal, deposited_value)
}

public fun principal_after_live_withdraw(current_principal: u64, current_value: u64, withdrawn_value: u64): u64 {
    if (current_principal == 0 || current_value == 0 || withdrawn_value >= current_value) {
        0
    } else {
        math::safe_sub(current_principal, math::mul_div(current_principal, withdrawn_value, current_value))
    }
}

public fun value_after_live_withdraw(current_value: u64, withdrawn_value: u64): u64 {
    if (withdrawn_value >= current_value) {
        0
    } else {
        current_value - withdrawn_value
    }
}

public fun accrued_yield_amount(principal: u64, current_value: u64): u64 {
    if (current_value > principal) {
        current_value - principal
    } else {
        0
    }
}

/// Withdraw up to `amount` from a lending position. Returns (next_receipt_id, withdrawn, remaining).
public fun withdraw_from_lending(
    _cfg: &config::Config,
    receipt_id: address,
    current_value: u64,
    amount: u64,
): (address, u64, u64) {
    let withdrawn = if (current_value < amount) { current_value } else { amount };
    let remaining = current_value - withdrawn;
    let next_receipt = if (remaining > 0) { receipt_id } else { @0x0 };
    (next_receipt, withdrawn, remaining)
}

/// Deterministic mock accrual used by P2 accounting tests.
public fun accrue_yield(cfg: &config::Config, current_value: u64): u64 {
    if (!is_available(cfg) || current_value == 0) {
        current_value
    } else {
        math::safe_add(current_value, math::mul_div(current_value, MOCK_YIELD_BPS_PER_CYCLE, 10000))
    }
}

/// Returns the tracked accounting value of the yield position.
public fun get_yield_value(_cfg: &config::Config, current_value: u64): u64 {
    current_value
}
