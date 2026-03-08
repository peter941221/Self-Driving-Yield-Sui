module self_driving_yield::queue;

use self_driving_yield::errors;
use self_driving_yield::math;
use self_driving_yield::sdye;
use sui::balance;

public enum RequestStatus has copy, drop, store {
    Pending,
    Ready,
    Claimed,
}

public fun status_pending(): RequestStatus { RequestStatus::Pending }
public fun status_ready(): RequestStatus { RequestStatus::Ready }
public fun status_claimed(): RequestStatus { RequestStatus::Claimed }

public fun is_pending(s: &RequestStatus): bool {
    match (s) {
        RequestStatus::Pending => true,
        _ => false,
    }
}

public fun is_ready(s: &RequestStatus): bool {
    match (s) {
        RequestStatus::Ready => true,
        _ => false,
    }
}

public fun is_claimed(s: &RequestStatus): bool {
    match (s) {
        RequestStatus::Claimed => true,
        _ => false,
    }
}

public struct WithdrawRequest has copy, drop, store {
    request_id: u64,
    owner: address,
    shares: u64,
    usdc_amount: u64,
    status: RequestStatus,
    created_at_ms: u64,
}

public fun request_id(r: &WithdrawRequest): u64 { r.request_id }
public fun owner(r: &WithdrawRequest): address { r.owner }
public fun shares(r: &WithdrawRequest): u64 { r.shares }
public fun usdc_amount(r: &WithdrawRequest): u64 { r.usdc_amount }
public fun status(r: &WithdrawRequest): RequestStatus { r.status }

public fun set_status_claimed(r: &mut WithdrawRequest) {
    r.status = RequestStatus::Claimed;
}

public struct QueueState has store, drop {
    next_request_id: u64,
    total_pending_shares: u64,
    total_pending_usdc: u64,
    total_ready_usdc: u64,
    requests: vector<WithdrawRequest>,
}

public fun new_state(): QueueState {
    QueueState {
        next_request_id: 0,
        total_pending_shares: 0,
        total_pending_usdc: 0,
        total_ready_usdc: 0,
        requests: vector::empty(),
    }
}

public fun len(q: &QueueState): u64 { vector::length(&q.requests) }
public fun next_request_id(q: &QueueState): u64 { q.next_request_id }
public fun total_pending_shares(q: &QueueState): u64 { q.total_pending_shares }
public fun total_pending_usdc(q: &QueueState): u64 { q.total_pending_usdc }
public fun total_ready_usdc(q: &QueueState): u64 { q.total_ready_usdc }

public fun request_at(q: &QueueState, idx: u64): WithdrawRequest {
    *vector::borrow(&q.requests, idx)
}

public fun borrow_request(q: &QueueState, request_id: u64): &WithdrawRequest {
    vector::borrow(&q.requests, request_id)
}

public fun borrow_request_mut(q: &mut QueueState, request_id: u64): &mut WithdrawRequest {
    vector::borrow_mut(&mut q.requests, request_id)
}

/// Claim a Ready request: update status and decrease reserved Ready USDC totals.
public fun claim_ready(q: &mut QueueState, request_id: u64) {
    let usdc_amount = {
        let r = vector::borrow(&q.requests, request_id);
        assert!(is_ready(&r.status), errors::e_request_not_ready());
        r.usdc_amount
    };

    q.total_ready_usdc = math::safe_sub(q.total_ready_usdc, usdc_amount);
    let r_mut = vector::borrow_mut(&mut q.requests, request_id);
    r_mut.status = RequestStatus::Claimed;
}

public fun enqueue(
    q: &mut QueueState,
    owner: address,
    shares: u64,
    usdc_amount: u64,
    created_at_ms: u64,
): u64 {
    assert!(shares > 0, errors::e_zero_amount());
    assert!(usdc_amount > 0, errors::e_zero_usdc_out());

    let request_id = q.next_request_id;
    q.next_request_id = request_id + 1;

    q.total_pending_shares = math::safe_add(q.total_pending_shares, shares);
    q.total_pending_usdc = math::safe_add(q.total_pending_usdc, usdc_amount);

    vector::push_back(
        &mut q.requests,
        WithdrawRequest {
            request_id,
            owner,
            shares,
            usdc_amount,
            status: RequestStatus::Pending,
            created_at_ms,
        },
    );
    request_id
}

/// Mark as Ready in FIFO order while treasury can cover the pending USDC.
/// Returns number of requests transitioned Pending->Ready.
public fun process_queue(q: &mut QueueState, treasury_usdc: &mut u64): u64 {
    let mut i = 0;
    let mut moved = 0;
    let n = vector::length(&q.requests);

    if (n == 0 || q.total_pending_shares == 0 || q.total_pending_usdc == 0) {
        return 0
    };

    while (i < n) {
        let req_ref = vector::borrow_mut(&mut q.requests, i);
        if (!is_pending(&req_ref.status)) {
            i = i + 1;
            continue
        };
        if (*treasury_usdc < req_ref.usdc_amount) {
            break
        };

        *treasury_usdc = *treasury_usdc - req_ref.usdc_amount;
        req_ref.status = RequestStatus::Ready;
        q.total_pending_shares = math::safe_sub(q.total_pending_shares, req_ref.shares);
        q.total_pending_usdc = math::safe_sub(q.total_pending_usdc, req_ref.usdc_amount);
        q.total_ready_usdc = math::safe_add(q.total_ready_usdc, req_ref.usdc_amount);
        moved = moved + 1;
        i = i + 1;
    };
    moved
}

/// On-chain shared queue object wrapper.
///
/// Stores the pure `QueueState` and a parallel vector of locked `Balance<SDYE>` so entry
/// functions can custody share tokens for queued withdrawals.
public struct WithdrawalQueue has key, store {
    id: UID,
    state: QueueState,
    locked_shares: vector<balance::Balance<sdye::SDYE>>,
}

public fun new_queue(ctx: &mut TxContext): WithdrawalQueue {
    WithdrawalQueue {
        id: object::new(ctx),
        state: new_state(),
        locked_shares: vector::empty(),
    }
}

public fun state(q: &WithdrawalQueue): &QueueState { &q.state }
public fun state_mut(q: &mut WithdrawalQueue): &mut QueueState { &mut q.state }

/// Attach locked shares for a newly enqueued request (Queued path only).
/// Must be called exactly once per request, immediately after `enqueue`.
public fun lock_shares_for_new_request(
    q: &mut WithdrawalQueue,
    request_id: u64,
    shares: balance::Balance<sdye::SDYE>,
) {
    assert!(vector::length(&q.locked_shares) == request_id, errors::e_overflow());
    vector::push_back(&mut q.locked_shares, shares);
}

/// Move out all locked shares for the request, leaving zero behind.
public fun take_locked_shares(
    q: &mut WithdrawalQueue,
    request_id: u64,
): balance::Balance<sdye::SDYE> {
    let b_ref = vector::borrow_mut(&mut q.locked_shares, request_id);
    balance::withdraw_all(b_ref)
}
