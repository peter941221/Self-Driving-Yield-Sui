module self_driving_yield::yield_source;

use self_driving_yield::config;
use self_driving_yield::math;

const MOCK_YIELD_BPS_PER_CYCLE: u64 = 2;

/// Returns true when a lending market id is configured (P2).
public fun is_available(cfg: &config::Config): bool {
    config::lending_market_id(cfg) != @0x0
}

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