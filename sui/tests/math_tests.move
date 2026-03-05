module self_driving_yield::math_tests;

use self_driving_yield::errors;
use self_driving_yield::math;

#[test]
fun safe_mul_basic() {
    let z = math::safe_mul(7, 6);
    assert!(z == 42, 0);
}

#[test]
fun mul_div_floor() {
    let z = math::mul_div(100, 2, 3);
    assert!(z == 66, 0);
}

#[test]
#[expected_failure(abort_code = errors::E_OVERFLOW, location = self_driving_yield::math)]
fun safe_mul_overflow_aborts() {
    let max: u64 = 18446744073709551615;
    let _ = math::safe_mul(max, 2);
}

#[test]
#[expected_failure(abort_code = errors::E_DIV_BY_ZERO, location = self_driving_yield::math)]
fun safe_div_zero_aborts() {
    let _ = math::safe_div(1, 0);
}

#[test]
fun mul_div_large_numbers_exact() {
    let max: u64 = 18446744073709551615;
    let z = math::mul_div(max, max, max);
    assert!(z == max, 0);
}

#[test]
fun safe_mul_zero_returns_zero() {
    assert!(math::safe_mul(0, 123) == 0, 0);
    assert!(math::safe_mul(123, 0) == 0, 0);
}

#[test]
fun safe_div_basic() {
    assert!(math::safe_div(7, 2) == 3, 0);
}

#[test]
#[expected_failure(abort_code = errors::E_OVERFLOW, location = self_driving_yield::math)]
fun safe_add_overflow_aborts() {
    let max: u64 = 18446744073709551615;
    let _ = math::safe_add(max, 1);
}

#[test]
#[expected_failure(abort_code = errors::E_OVERFLOW, location = self_driving_yield::math)]
fun safe_sub_underflow_aborts() {
    let _ = math::safe_sub(0, 1);
}

#[test]
#[expected_failure(abort_code = errors::E_DIV_BY_ZERO, location = self_driving_yield::math)]
fun mul_div_zero_denominator_aborts() {
    let _ = math::mul_div(1, 1, 0);
}
