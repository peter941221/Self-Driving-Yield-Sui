module formal::yield_source_proofs;

#[spec_only]
use prover::prover::{requires, ensures};

use self_driving_yield::config;
use self_driving_yield::yield_source;

#[spec(prove)]
fun normalize_receipt_zero_when_invalid_spec(cfg: &config::Config, receipt_id: address, tracked_value: u64): address {
    requires(!yield_source::is_available(cfg) || receipt_id == @0x0 || tracked_value == 0);
    let result = yield_source::normalize_live_receipt_id(cfg, receipt_id, tracked_value);
    ensures(result == @0x0);
    result
}

#[spec(prove)]
fun normalize_receipt_preserves_valid_id_spec(cfg: &config::Config, receipt_id: address, tracked_value: u64): address {
    requires(yield_source::is_available(cfg));
    requires(receipt_id != @0x0);
    requires(tracked_value > 0);
    let result = yield_source::normalize_live_receipt_id(cfg, receipt_id, tracked_value);
    ensures(result == receipt_id);
    result
}

#[spec(prove)]
fun full_withdraw_zeroes_remaining_value_spec(current_value: u64, withdrawn_value: u64): u64 {
    requires(withdrawn_value >= current_value);
    let result = yield_source::value_after_live_withdraw(current_value, withdrawn_value);
    ensures(result == 0);
    result
}

#[spec(prove)]
fun partial_withdraw_subtracts_remaining_value_spec(current_value: u64, withdrawn_value: u64): u64 {
    requires(withdrawn_value < current_value);
    let result = yield_source::value_after_live_withdraw(current_value, withdrawn_value);
    ensures(result + withdrawn_value == current_value);
    result
}

#[spec(prove)]
fun full_withdraw_zeroes_principal_spec(current_principal: u64, current_value: u64, withdrawn_value: u64): u64 {
    requires(withdrawn_value >= current_value || current_principal == 0 || current_value == 0);
    let result = yield_source::principal_after_live_withdraw(current_principal, current_value, withdrawn_value);
    ensures(result == 0);
    result
}

#[spec(prove)]
fun accrued_yield_is_non_negative_spec(principal: u64, current_value: u64): u64 {
    let result = yield_source::accrued_yield_amount(principal, current_value);
    ensures(result + principal >= principal);
    ensures(result == 0 || current_value > principal);
    result
}
