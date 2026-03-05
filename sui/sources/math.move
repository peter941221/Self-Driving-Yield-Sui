module self_driving_yield::math;

use self_driving_yield::errors;

const U64_MAX: u64 = 18446744073709551615;

public fun safe_add(x: u64, y: u64): u64 {
    assert!(x <= U64_MAX - y, errors::e_overflow());
    x + y
}

public fun safe_sub(x: u64, y: u64): u64 {
    assert!(x >= y, errors::e_overflow());
    x - y
}

public fun safe_mul(x: u64, y: u64): u64 {
    if (x == 0 || y == 0) {
        0
    } else {
        assert!(x <= U64_MAX / y, errors::e_overflow());
        x * y
    }
}

public fun safe_div(x: u64, y: u64): u64 {
    assert!(y != 0, errors::e_div_by_zero());
    x / y
}

/// floor(x*y/d) with overflow checks.
public fun mul_div(x: u64, y: u64, d: u64): u64 {
    assert!(d != 0, errors::e_div_by_zero());
    let prod: u128 = (x as u128) * (y as u128);
    let q: u128 = prod / (d as u128);
    assert!(q <= (U64_MAX as u128), errors::e_overflow());
    q as u64
}
