module formal::queue_proofs;

#[spec_only]
use prover::prover::{requires, ensures};

use self_driving_yield::queue;

#[spec(prove)]
fun enqueue_single_request_updates_totals_spec(owner: address, shares: u64, usdc_amount: u64, created_at_ms: u64): u64 {
    requires(shares > 0);
    requires(usdc_amount > 0);
    let mut state = queue::new_state();
    let result = queue::enqueue(&mut state, owner, shares, usdc_amount, created_at_ms);
    let req = queue::request_at(&state, 0);
    let req_status = queue::status(&req);
    ensures(result == 0);
    ensures(queue::len(&state) == 1);
    ensures(queue::total_pending_shares(&state) == shares);
    ensures(queue::total_pending_usdc(&state) == usdc_amount);
    ensures(queue::total_ready_usdc(&state) == 0);
    ensures(queue::request_id(&req) == 0);
    ensures(queue::owner(&req) == owner);
    ensures(queue::shares(&req) == shares);
    ensures(queue::usdc_amount(&req) == usdc_amount);
    ensures(queue::is_pending(&req_status));
    result
}

#[spec(prove)]
fun new_queue_state_starts_empty_spec(): u64 {
    let state = queue::new_state();
    let result = queue::len(&state);
    ensures(result == 0);
    ensures(queue::total_pending_shares(&state) == 0);
    ensures(queue::total_pending_usdc(&state) == 0);
    ensures(queue::total_ready_usdc(&state) == 0);
    result
}

#[spec(prove, target = self_driving_yield::queue::claim_ready)]
fun claim_ready_reduces_reserved_total_spec(q: &mut queue::QueueState, request_id: u64) {
    requires(request_id < queue::len(q));
    let old_len = queue::len(q);
    let old_ready = queue::total_ready_usdc(q);
    let req = queue::request_at(q, request_id);
    let req_status = queue::status(&req);
    let req_usdc = queue::usdc_amount(&req);
    requires(queue::is_ready(&req_status));
    requires(old_ready >= req_usdc);

    queue::claim_ready(q, request_id);

    ensures(queue::total_ready_usdc(q).to_int().add(req_usdc.to_int()) == old_ready.to_int());
    ensures(queue::len(q) == old_len);
}

#[spec(prove, target = self_driving_yield::queue::process_queue)]
fun process_queue_empty_queue_target_spec(q: &mut queue::QueueState, treasury_usdc: &mut u64): u64 {
    requires(*treasury_usdc == 0);
    requires(queue::len(q) == 0);
    requires(queue::total_pending_shares(q) == 0);
    requires(queue::total_pending_usdc(q) == 0);
    requires(queue::total_ready_usdc(q) == 0);

    let result = queue::process_queue(q, treasury_usdc);

    ensures(result == 0);
    ensures(*treasury_usdc == 0);
    result
}
