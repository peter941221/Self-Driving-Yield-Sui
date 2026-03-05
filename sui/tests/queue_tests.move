module self_driving_yield::queue_tests;

use self_driving_yield::queue;

#[test]
fun enqueue_increments_ids_and_tracks_pending_totals() {
    let mut q = queue::new_state();

    let id0 = queue::enqueue(&mut q, @0x1, 10, 100, 1);
    let id1 = queue::enqueue(&mut q, @0x2, 5, 50, 2);

    assert!(id0 == 0, 0);
    assert!(id1 == 1, 0);
    assert!(queue::len(&q) == 2, 0);
    assert!(queue::total_pending_shares(&q) == 15, 0);
    assert!(queue::total_pending_usdc(&q) == 150, 0);

    let r0 = queue::request_at(&q, 0);
    let s0 = queue::status(&r0);
    assert!(queue::is_pending(&s0), 0);
}

#[test]
fun process_queue_marks_ready_fifo_and_updates_pending_totals() {
    let mut q = queue::new_state();
    let _ = queue::enqueue(&mut q, @0x1, 10, 100, 1);
    let _ = queue::enqueue(&mut q, @0x2, 5, 50, 2);

    let mut treasury: u64 = 120;
    let moved = queue::process_queue(&mut q, &mut treasury);
    assert!(moved == 1, 0);

    let r0 = queue::request_at(&q, 0);
    let r1 = queue::request_at(&q, 1);
    let s0 = queue::status(&r0);
    let s1 = queue::status(&r1);
    assert!(queue::is_ready(&s0), 0);
    assert!(queue::is_pending(&s1), 0);

    assert!(queue::total_pending_shares(&q) == 5, 0);
    assert!(queue::total_pending_usdc(&q) == 50, 0);
}

#[test]
fun process_queue_skips_ready_requests_and_processes_later_pending() {
    let mut q = queue::new_state();
    let _ = queue::enqueue(&mut q, @0x1, 10, 100, 1);
    let _ = queue::enqueue(&mut q, @0x2, 5, 50, 2);

    // First call moves request 0 to Ready only (120 covers 100 but not 50).
    let mut t1: u64 = 120;
    let moved1 = queue::process_queue(&mut q, &mut t1);
    assert!(moved1 == 1, 0);

    // Second call should skip request 0 (Ready) and move request 1.
    let mut t2: u64 = 60;
    let moved2 = queue::process_queue(&mut q, &mut t2);
    assert!(moved2 == 1, 0);

    let r0 = queue::request_at(&q, 0);
    let r1 = queue::request_at(&q, 1);
    assert!(queue::is_ready(&queue::status(&r0)), 0);
    assert!(queue::is_ready(&queue::status(&r1)), 0);
    assert!(queue::total_pending_shares(&q) == 0, 0);
    assert!(queue::total_pending_usdc(&q) == 0, 0);
}

#[test]
fun queue_helper_functions_are_usable() {
    let pending = queue::status_pending();
    let ready = queue::status_ready();
    let claimed = queue::status_claimed();

    assert!(queue::is_pending(&pending), 0);
    assert!(queue::is_ready(&ready), 0);
    assert!(queue::is_claimed(&claimed), 0);

    assert!(!queue::is_pending(&ready), 0);
    assert!(!queue::is_ready(&claimed), 0);
    assert!(!queue::is_claimed(&pending), 0);

    let mut q = queue::new_state();
    let id = queue::enqueue(&mut q, @0x1, 7, 70, 123);
    assert!(id == 0, 0);
    assert!(queue::len(&q) == 1, 0);

    let r = queue::request_at(&q, 0);
    assert!(queue::request_id(&r) == 0, 0);
    assert!(queue::owner(&r) == @0x1, 0);
    assert!(queue::shares(&r) == 7, 0);
    assert!(queue::usdc_amount(&r) == 70, 0);
    assert!(queue::is_pending(&queue::status(&r)), 0);

    let r_mut = queue::borrow_request_mut(&mut q, 0);
    queue::set_status_claimed(r_mut);
    let r2 = queue::request_at(&q, 0);
    assert!(queue::is_claimed(&queue::status(&r2)), 0);
}
