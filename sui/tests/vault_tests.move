module self_driving_yield::vault_tests;

use self_driving_yield::errors;
use self_driving_yield::oracle;
use self_driving_yield::queue;
use self_driving_yield::vault;

#[test]
fun first_deposit_is_1_to_1() {
    let shares = vault::calc_shares_to_mint(100, 0, 0);
    assert!(shares == 100, 0);
}

#[test]
fun proportional_minting() {
    let shares = vault::calc_shares_to_mint(100, 1000, 1000);
    assert!(shares == 100, 0);
}

#[test]
fun allocation_calm() {
    let regime = vault::regime_calm();
    let (y, lp, buf) = vault::get_allocation(&regime);
    assert!(y == 4000, 0);
    assert!(lp == 5700, 0);
    assert!(buf == 300, 0);
}

#[test]
fun deposit_updates_totals() {
    let mut s = vault::new_state();
    let shares = vault::deposit(&mut s, 1000);
    assert!(shares == 1000, 0);
    assert!(vault::total_assets(&s) == 1000, 0);
    assert!(vault::total_shares(&s) == 1000, 0);
    assert!(vault::treasury_usdc(&s) == 1000, 0);
}

#[test]
fun deposit_is_proportional_after_first() {
    let mut s = vault::new_state();
    let s1 = vault::deposit(&mut s, 1000);
    let s2 = vault::deposit(&mut s, 500);
    assert!(s1 == 1000, 0);
    assert!(s2 == 500, 0);
    assert!(vault::total_assets(&s) == 1500, 0);
    assert!(vault::total_shares(&s) == 1500, 0);
    assert!(vault::treasury_usdc(&s) == 1500, 0);
}

#[test]
#[expected_failure(abort_code = errors::E_ONLY_UNWIND, location = self_driving_yield::vault)]
fun deposit_rejected_in_only_unwind() {
    let mut s = vault::new_state();
    vault::set_risk_mode(&mut s, vault::risk_only_unwind());
    let _ = vault::deposit(&mut s, 1);
}

#[test]
fun request_withdraw_instant_when_treasury_sufficient() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();

    let _ = vault::deposit(&mut s, 1000);
    let plan = vault::request_withdraw(&mut s, &mut q, @0x1, 200, 123);
    assert!(vault::plan_is_instant(&plan), 0);
    assert!(vault::instant_usdc_out(&plan) == 200, 0);

    assert!(vault::treasury_usdc(&s) == 800, 0);
    assert!(vault::total_assets(&s) == 800, 0);
    assert!(vault::total_shares(&s) == 800, 0);
    assert!(queue::len(&q) == 0, 0);
}

#[test]
fun request_withdraw_queues_when_treasury_insufficient() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();

    let _ = vault::deposit(&mut s, 1000);
    vault::set_treasury_usdc_for_testing(&mut s, 100);

    let plan = vault::request_withdraw(&mut s, &mut q, @0x1, 200, 999);
    assert!(vault::plan_is_queued(&plan), 0);
    assert!(vault::queued_request_id(&plan) == 0, 0);
    assert!(vault::queued_usdc_amount(&plan) == 200, 0);

    assert!(vault::treasury_usdc(&s) == 100, 0);
    assert!(vault::total_assets(&s) == 1000, 0);
    assert!(vault::total_shares(&s) == 1000, 0);
    assert!(queue::len(&q) == 1, 0);
    assert!(queue::total_pending_shares(&q) == 200, 0);
    assert!(queue::total_pending_usdc(&q) == 200, 0);
}

#[test]
fun claim_transfers_when_ready_and_owner_matches() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();

    let _ = vault::deposit(&mut s, 1000);
    vault::set_treasury_usdc_for_testing(&mut s, 100);
    let plan = vault::request_withdraw(&mut s, &mut q, @0x1, 200, 999);
    assert!(vault::plan_is_queued(&plan), 0);

    // Simulate cycle unwind increasing treasury.
    vault::set_treasury_usdc_for_testing(&mut s, 500);
    let mut treasury = vault::treasury_usdc(&s);
    let moved = queue::process_queue(&mut q, &mut treasury);
    assert!(moved == 1, 0);

    let usdc_out = vault::claim(&mut s, &mut q, 0, @0x1);
    assert!(usdc_out == 200, 0);
    assert!(vault::treasury_usdc(&s) == 300, 0);
    assert!(vault::total_assets(&s) == 800, 0);
    assert!(vault::total_shares(&s) == 800, 0);

    let r0 = queue::request_at(&q, 0);
    let st = queue::status(&r0);
    assert!(queue::is_claimed(&st), 0);
}

#[test]
#[expected_failure(abort_code = errors::E_NOT_OWNER, location = self_driving_yield::vault)]
fun claim_rejected_for_non_owner() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();

    let _ = vault::deposit(&mut s, 1000);
    vault::set_treasury_usdc_for_testing(&mut s, 100);
    let plan = vault::request_withdraw(&mut s, &mut q, @0x1, 200, 999);
    assert!(vault::plan_is_queued(&plan), 0);

    vault::set_treasury_usdc_for_testing(&mut s, 500);
    let mut treasury = vault::treasury_usdc(&s);
    let _ = queue::process_queue(&mut q, &mut treasury);

    let _ = vault::claim(&mut s, &mut q, 0, @0x2);
}

#[test]
#[expected_failure(abort_code = 10, location = self_driving_yield::vault)]
fun claim_rejected_when_request_not_ready() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();

    let _ = vault::deposit(&mut s, 1000);
    vault::set_treasury_usdc_for_testing(&mut s, 0);
    let plan = vault::request_withdraw(&mut s, &mut q, @0x1, 200, 999);
    assert!(vault::plan_is_queued(&plan), 0);

    // Still Pending (not processed) => claim should abort.
    let _ = vault::claim(&mut s, &mut q, 0, @0x1);
}

#[test]
#[expected_failure(abort_code = 12, location = self_driving_yield::vault)]
fun claim_rejected_when_treasury_insufficient() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();

    let _ = vault::deposit(&mut s, 1000);
    vault::set_treasury_usdc_for_testing(&mut s, 0);
    let plan = vault::request_withdraw(&mut s, &mut q, @0x1, 200, 999);
    assert!(vault::plan_is_queued(&plan), 0);

    // Mark request Ready, but keep vault treasury at 0 => claim should abort with treasury insufficient.
    let mut t: u64 = 200;
    let _ = queue::process_queue(&mut q, &mut t);
    let _ = vault::claim(&mut s, &mut q, 0, @0x1);
}

#[test]
#[expected_failure(abort_code = 8, location = self_driving_yield::vault)]
fun request_withdraw_rejected_when_shares_exceed_total() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();

    // total_shares = 0
    let _ = vault::request_withdraw(&mut s, &mut q, @0x1, 1, 1);
}

#[test]
#[expected_failure(abort_code = 9, location = self_driving_yield::vault)]
fun queued_accessors_abort_on_instant_plan() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();

    let _ = vault::deposit(&mut s, 1000);
    let plan = vault::request_withdraw(&mut s, &mut q, @0x1, 1, 1);
    assert!(vault::plan_is_instant(&plan), 0);

    let _ = vault::queued_request_id(&plan);
}

#[test]
#[expected_failure(abort_code = 9, location = self_driving_yield::vault)]
fun instant_accessors_abort_on_queued_plan() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();

    let _ = vault::deposit(&mut s, 1000);
    vault::set_treasury_usdc_for_testing(&mut s, 0);
    let plan = vault::request_withdraw(&mut s, &mut q, @0x1, 200, 1);
    assert!(vault::plan_is_queued(&plan), 0);

    let _ = vault::instant_usdc_out(&plan);
}

#[test]
#[expected_failure(abort_code = 2, location = self_driving_yield::vault)]
fun share_math_rejects_zero_amounts() {
    let _ = vault::calc_shares_to_mint(0, 0, 0);
}

#[test]
#[expected_failure(abort_code = 2, location = self_driving_yield::vault)]
fun redeem_math_rejects_zero_shares() {
    let _ = vault::calc_usdc_to_redeem(0, 1, 1);
}

#[test]
#[expected_failure(abort_code = 2, location = self_driving_yield::vault)]
fun request_withdraw_rejects_zero_shares() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();
    let _ = vault::request_withdraw(&mut s, &mut q, @0x1, 0, 1);
}

#[test]
#[expected_failure(abort_code = 9, location = self_driving_yield::vault)]
fun queued_amount_accessor_aborts_on_instant_plan() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();

    let _ = vault::deposit(&mut s, 1000);
    let plan = vault::request_withdraw(&mut s, &mut q, @0x1, 1, 1);
    assert!(vault::plan_is_instant(&plan), 0);

    let _ = vault::queued_usdc_amount(&plan);
}

#[test]
fun vault_constants_and_accessors_work() {
    assert!(vault::max_bounty_bps() == 5, 0);

    let mut s = vault::new_state();
    let mut q = queue::new_state();
    let mut o = oracle::new();

    vault::cycle(
        &mut s,
        &mut q,
        &mut o,
        oracle::price_precision(),
        1000,
        0,
        0,
    );

    assert!(vault::last_cycle_ts_ms(&s) == 1000, 0);
    assert!(!vault::is_only_unwind(&vault::risk_normal()), 0);
}

#[test]
fun cycle_pays_bounty_capped_by_max_bps() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();
    let mut o = oracle::new();

    let _ = vault::deposit(&mut s, 10000);

    let (_moved, bounty) = vault::cycle(
        &mut s,
        &mut q,
        &mut o,
        oracle::price_precision(),
        1000,
        0,
        0,
    );

    assert!(bounty == 5, 0);
    assert!(vault::treasury_usdc(&s) == 9995, 0);
    assert!(vault::total_assets(&s) == 9995, 0);
}

#[test]
#[expected_failure(abort_code = errors::E_CYCLE_TOO_EARLY, location = self_driving_yield::vault)]
fun cycle_enforces_min_interval() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();
    let mut o = oracle::new();

    vault::cycle(
        &mut s,
        &mut q,
        &mut o,
        oracle::price_precision(),
        1000,
        1000,
        0,
    );

    // Too early: 1500 < 1000 + 1000
    vault::cycle(
        &mut s,
        &mut q,
        &mut o,
        oracle::price_precision(),
        1500,
        1000,
        0,
    );
}

#[test]
fun cycle_sets_only_unwind_when_oracle_regime_is_storm() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();
    let mut o = oracle::new();

    let p = oracle::price_precision();
    let hi = p + 30_000_000; // +3.00%
    let lo = p - 30_000_000; // -3.00%

    let mut ts: u64 = 0;
    let mut i: u64 = 0;
    while (i < 12) {
        ts = ts + 1000;
        let price = if (i % 2 == 0) { hi } else { lo };
        vault::cycle(&mut s, &mut q, &mut o, price, ts, 0, 0);
        i = i + 1;
    };

    let m = vault::risk_mode(&s);
    assert!(vault::is_only_unwind(&m), 0);
}

#[test]
fun cycle_never_spends_reserved_ready_withdrawals() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();
    let mut o = oracle::new();

    // total_assets=10000 but treasury=100 simulates most assets deployed elsewhere.
    let _ = vault::deposit(&mut s, 10000);
    vault::set_treasury_usdc_for_testing(&mut s, 100);

    // Pending request that will become Ready, reserving 99 USDC.
    let _ = queue::enqueue(&mut q, @0x1, 99, 99, 1);

    let (_moved, bounty) = vault::cycle(
        &mut s,
        &mut q,
        &mut o,
        oracle::price_precision(),
        1000,
        0,
        0,
    );

    // Remaining unreserved is 1, so bounty must be <= 1 even though max_bounty is 5.
    assert!(bounty == 1, 0);

    // Ready requests must stay reserved across cycles until claimed.
    let (_moved2, bounty2) = vault::cycle(
        &mut s,
        &mut q,
        &mut o,
        oracle::price_precision(),
        2000,
        0,
        0,
    );
    assert!(bounty2 == 0, 0);

    let usdc_out = vault::claim(&mut s, &mut q, 0, @0x1);
    assert!(usdc_out == 99, 0);
    assert!(vault::treasury_usdc(&s) == 0, 0);
}

#[test]
fun cycle_handles_pending_need_before_ready_reservation() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();
    let mut o = oracle::new();
    let _ = vault::deposit(&mut s, 1_000);
    vault::set_treasury_usdc_for_testing(&mut s, 100);
    let _ = queue::enqueue(&mut q, @0x1, 200, 200, 1);
    let (moved, bounty) = vault::cycle(&mut s, &mut q, &mut o, oracle::price_precision(), 1000, 0, 0);
    assert!(moved <= 100, 0);
    assert!(bounty == 0, 0);
}

#[test]
fun cycle_moves_ready_queue_and_can_zero_bounty() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();
    let mut o = oracle::new();
    let _ = vault::deposit(&mut s, 1_000);
    vault::set_treasury_usdc_for_testing(&mut s, 200);
    let _ = queue::enqueue(&mut q, @0x1, 200, 200, 1);
    let (moved, bounty) = vault::cycle(&mut s, &mut q, &mut o, oracle::price_precision(), 1000, 0, 0);
    assert!(moved <= 200, 0);
    assert!(bounty == 0, 0);
    assert!(vault::last_cycle_ts_ms(&s) == 1000, 0);
}

#[test]
fun only_unwind_requires_two_safe_cycles_to_restore() {
    let mut s = vault::new_state();
    let storm = vault::regime_storm();
    let normal = vault::regime_normal();
    vault::apply_cycle_regime(&mut s, &storm);
    assert!(vault::is_only_unwind(&vault::risk_mode(&s)), 0);
    assert!(vault::safe_cycles_since_storm(&s) == 0, 0);

    vault::apply_cycle_regime_with_guards(&mut s, &normal, 0, 0, 0);
    assert!(vault::is_only_unwind(&vault::risk_mode(&s)), 0);
    assert!(vault::safe_cycles_since_storm(&s) == 1, 0);

    vault::apply_cycle_regime_with_guards(&mut s, &normal, 0, 0, 0);
    assert!(!vault::is_only_unwind(&vault::risk_mode(&s)), 0);
    assert!(vault::safe_cycles_since_storm(&s) == vault::safe_cycles_to_restore(), 0);
}

#[test]
fun calm_normal_storm_calm_allocation_path_is_consistent() {
    let calm = vault::regime_calm();
    let normal = vault::regime_normal();
    let storm = vault::regime_storm();

    let (y_calm, lp_calm, buf_calm) = vault::get_allocation(&calm);
    let (y_normal, lp_normal, buf_normal) = vault::get_allocation(&normal);
    let (y_storm, lp_storm, buf_storm) = vault::get_allocation(&storm);

    assert!(lp_calm > y_calm, 0);
    assert!(y_normal > lp_normal, 0);
    assert!(y_storm > y_normal, 0);
    assert!(lp_storm < lp_normal, 0);
    assert!(buf_calm == 300 && buf_normal == 300 && buf_storm == 300, 0);
}

#[test]
fun set_risk_mode_restores_safe_counter_when_back_to_normal() {
    let mut s = vault::new_state();

    vault::set_risk_mode(&mut s, vault::risk_only_unwind());
    assert!(vault::is_only_unwind(&vault::risk_mode(&s)), 0);
    assert!(vault::safe_cycles_since_storm(&s) == 0, 0);

    vault::set_risk_mode(&mut s, vault::risk_normal());
    assert!(!vault::is_only_unwind(&vault::risk_mode(&s)), 0);
    assert!(vault::safe_cycles_since_storm(&s) == vault::safe_cycles_to_restore(), 0);
    assert!(vault::max_bounty_bps() == 5, 0);
}

#[test]
fun guarded_restore_requires_low_queue_and_treasury_coverage() {
    let mut s = vault::new_state();
    let storm = vault::regime_storm();
    let normal = vault::regime_normal();

    vault::apply_cycle_regime(&mut s, &storm);
    assert!(vault::is_only_unwind(&vault::risk_mode(&s)), 0);
    assert!(vault::safe_cycles_since_storm(&s) == 0, 0);

    vault::apply_cycle_regime_with_guards(&mut s, &normal, 0, 2_000, 1);
    assert!(vault::is_only_unwind(&vault::risk_mode(&s)), 0);
    assert!(vault::safe_cycles_since_storm(&s) == 0, 0);

    vault::set_treasury_usdc_for_testing(&mut s, 100);
    vault::apply_cycle_regime_with_guards(&mut s, &normal, 0, 500, 100);
    assert!(vault::is_only_unwind(&vault::risk_mode(&s)), 0);
    assert!(vault::safe_cycles_since_storm(&s) == 1, 0);

    vault::apply_cycle_regime_with_guards(&mut s, &normal, 0, 500, 100);
    assert!(!vault::is_only_unwind(&vault::risk_mode(&s)), 0);
    assert!(vault::safe_cycles_since_storm(&s) == vault::safe_cycles_to_restore(), 0);
}

#[test]
fun guarded_restore_resets_when_queue_pressure_stays_high() {
    let mut s = vault::new_state();
    let storm = vault::regime_storm();
    let normal = vault::regime_normal();
    vault::apply_cycle_regime(&mut s, &storm);
    vault::apply_cycle_regime_with_guards(&mut s, &normal, 0, 500, 0);
    assert!(vault::safe_cycles_since_storm(&s) == 1, 0);
    vault::apply_cycle_regime_with_guards(&mut s, &normal, 0, 2_000, 1);
    assert!(vault::is_only_unwind(&vault::risk_mode(&s)), 0);
    assert!(vault::safe_cycles_since_storm(&s) == 0, 0);
}

#[test]
fun guarded_restore_resets_when_effective_vol_stays_high() {
    let mut s = vault::new_state();
    let storm = vault::regime_storm();
    let normal = vault::regime_normal();
    vault::apply_cycle_regime(&mut s, &storm);
    vault::apply_cycle_regime_with_guards(&mut s, &normal, 0, 0, 0);
    assert!(vault::safe_cycles_since_storm(&s) == 1, 0);
    vault::apply_cycle_regime_with_guards(&mut s, &normal, oracle::calm_exit_vol_bps(), 0, 0);
    assert!(vault::is_only_unwind(&vault::risk_mode(&s)), 0);
    assert!(vault::safe_cycles_since_storm(&s) == 0, 0);
}

#[test]
fun guarded_restore_resets_when_treasury_stays_below_reserve_and_queue_exists() {
    let mut s = vault::new_state();
    let storm = vault::regime_storm();
    let normal = vault::regime_normal();
    vault::apply_cycle_regime(&mut s, &storm);
    vault::set_treasury_usdc_for_testing(&mut s, 50);
    vault::apply_cycle_regime_with_guards(&mut s, &normal, 0, 500, 100);
    assert!(vault::is_only_unwind(&vault::risk_mode(&s)), 0);
    assert!(vault::safe_cycles_since_storm(&s) == 0, 0);
}

#[test]
fun guarded_restore_allows_zero_queue_without_treasury_cover() {
    let mut s = vault::new_state();
    let storm = vault::regime_storm();
    let normal = vault::regime_normal();
    vault::apply_cycle_regime(&mut s, &storm);
    vault::set_treasury_usdc_for_testing(&mut s, 0);
    vault::apply_cycle_regime_with_guards(&mut s, &normal, 0, 0, 1000);
    assert!(vault::safe_cycles_since_storm(&s) == 1, 0);
}

#[test]
fun guarded_restore_normal_mode_keeps_counter_full() {
    let mut s = vault::new_state();
    let normal = vault::regime_normal();
    vault::apply_cycle_regime_with_guards(&mut s, &normal, 0, 0, 0);
    assert!(!vault::is_only_unwind(&vault::risk_mode(&s)), 0);
    assert!(vault::safe_cycles_since_storm(&s) == vault::safe_cycles_to_restore(), 0);
    assert!(vault::restore_max_queue_pressure_bps() == 1000, 0);
}

#[test]
fun vault_cycle_with_confidence_and_plans_cover_direct_helpers() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();
    let mut o = oracle::new();

    let shares = vault::deposit(&mut s, 10_000);
    assert!(shares == 10_000, 0);
    assert!(vault::total_assets(&s) == 10_000, 0);
    assert!(vault::total_shares(&s) == 10_000, 0);
    assert!(vault::treasury_usdc(&s) == 10_000, 0);
    assert!(vault::last_cycle_ts_ms(&s) == 0, 0);

    let (moved, bounty) = vault::cycle_with_confidence(
        &mut s,
        &mut q,
        &mut o,
        oracle::price_precision(),
        15,
        1000,
        0,
        0,
    );
    assert!(moved == 0, 0);
    assert!(bounty == vault::max_bounty_bps(), 0);
    assert!(vault::last_cycle_ts_ms(&s) == 1000, 0);
    assert!(oracle::current_confidence_bps(&o) == 15, 0);

    let p1 = vault::request_withdraw(&mut s, &mut q, @0x1, 1_000, 2000);
    assert!(vault::plan_is_instant(&p1), 0);
    assert!(!vault::plan_is_queued(&p1), 0);
    assert!(vault::instant_usdc_out(&p1) > 0, 0);

    vault::set_treasury_usdc_for_testing(&mut s, 0);
    let p2 = vault::request_withdraw(&mut s, &mut q, @0x1, 1_000, 3000);
    assert!(vault::plan_is_queued(&p2), 0);
    assert!(!vault::plan_is_instant(&p2), 0);
    assert!(vault::queued_request_id(&p2) == 0, 0);
    assert!(vault::queued_usdc_amount(&p2) > 0, 0);
}

#[test]
fun cycle_bounty_helper_covers_zero_and_bound_cases() {
    assert!(vault::compute_cycle_bounty(0, 10_000) == 0, 0);
    assert!(vault::compute_cycle_bounty(10, 0) == 0, 0);
    assert!(vault::compute_cycle_bounty(100, 10_000) == 5, 0);
    assert!(vault::compute_cycle_bounty(3, 10_000) == 3, 0);
}

#[test]
fun vault_wrapper_helpers_cover_regime_and_risk_aliases() {
    let calm = vault::regime_calm();
    let normal = vault::regime_normal();
    let storm = vault::regime_storm();
    assert!(vault::is_regime_calm(&calm), 0);
    assert!(vault::is_regime_normal(&normal), 0);
    assert!(vault::is_regime_storm(&storm), 0);

    let rn = vault::risk_normal();
    let ru = vault::risk_only_unwind();
    assert!(!vault::is_only_unwind(&rn), 0);
    assert!(vault::is_only_unwind(&ru), 0);
}

#[test]
fun guarded_restore_storm_branch_forces_only_unwind() {
    let mut s = vault::new_state();
    vault::apply_cycle_regime_with_guards(&mut s, &vault::regime_storm(), 999, 9_999, 9_999);
    assert!(vault::is_only_unwind(&vault::risk_mode(&s)), 0);
    assert!(vault::safe_cycles_since_storm(&s) == 0, 0);
}

#[test]
fun redeem_helper_matches_expected_floor_math() {
    let out = vault::calc_usdc_to_redeem(250, 1_000, 1_000);
    assert!(out == 250, 0);
    let out2 = vault::calc_usdc_to_redeem(333, 1_000, 777);
    assert!(out2 == 428, 0);
}

#[test]
fun direct_apply_cycle_regime_helper_covers_storm_and_normal() {
    let mut s = vault::new_state();
    vault::apply_cycle_regime(&mut s, &vault::regime_storm());
    assert!(vault::is_only_unwind(&vault::risk_mode(&s)), 0);
    assert!(vault::safe_cycles_since_storm(&s) == 0, 0);
    vault::apply_cycle_regime(&mut s, &vault::regime_normal());
    assert!(vault::is_only_unwind(&vault::risk_mode(&s)), 0);
    assert!(vault::safe_cycles_since_storm(&s) == 1, 0);
}

#[test]
fun direct_claim_success_path_updates_totals() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();
    let _ = vault::deposit(&mut s, 1_000);
    vault::set_treasury_usdc_for_testing(&mut s, 1_000);
    let request_id = queue::enqueue(&mut q, @0x1, 200, 200, 1);
    let mut treasury_after_reserve = 1_000;
    let _moved = queue::process_queue(&mut q, &mut treasury_after_reserve);
    let usdc_out = vault::claim(&mut s, &mut q, request_id, @0x1);
    assert!(usdc_out == 200, 0);
    assert!(vault::treasury_usdc(&s) == 800, 0);
    assert!(vault::total_assets(&s) == 800, 0);
    assert!(vault::total_shares(&s) == 800, 0);
}

#[test, expected_failure(abort_code = errors::E_INVALID_PLAN, location = self_driving_yield::vault)]
fun queued_usdc_amount_aborts_on_instant_plan() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();
    let _ = vault::deposit(&mut s, 100);
    let plan = vault::request_withdraw(&mut s, &mut q, @0x1, 10, 1);
    assert!(vault::plan_is_instant(&plan), 0);
    let _ = vault::queued_usdc_amount(&plan);
}

#[test]
fun queued_usdc_amount_returns_value_for_queued_plan() {
    let mut s = vault::new_state();
    let mut q = queue::new_state();
    let _ = vault::deposit(&mut s, 1_000);
    vault::set_treasury_usdc_for_testing(&mut s, 0);
    let plan = vault::request_withdraw(&mut s, &mut q, @0x1, 200, 1);
    assert!(vault::plan_is_queued(&plan), 0);
    assert!(vault::queued_usdc_amount(&plan) > 0, 0);
}
