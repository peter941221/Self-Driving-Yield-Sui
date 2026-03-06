module self_driving_yield::errors_tests;

use self_driving_yield::errors;

#[test]
fun error_code_constants_match_functions() {
    assert!(errors::e_only_unwind() == 1, 0);
    assert!(errors::e_zero_amount() == 2, 0);
    assert!(errors::e_div_by_zero() == 3, 0);
    assert!(errors::e_overflow() == 4, 0);
    assert!(errors::e_snapshot_too_early() == 5, 0);
    assert!(errors::e_zero_shares() == 6, 0);
    assert!(errors::e_zero_usdc_out() == 7, 0);
    assert!(errors::e_insufficient_shares() == 8, 0);
    assert!(errors::e_invalid_plan() == 9, 0);
    assert!(errors::e_request_not_ready() == 10, 0);
    assert!(errors::e_not_owner() == 11, 0);
    assert!(errors::e_treasury_insufficient() == 12, 0);
    assert!(errors::e_cycle_too_early() == 13, 0);
    assert!(errors::e_adapter_not_implemented() == 14, 0);
}
