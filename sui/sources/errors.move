module self_driving_yield::errors;

const E_ONLY_UNWIND: u64 = 1;
const E_ZERO_AMOUNT: u64 = 2;
const E_DIV_BY_ZERO: u64 = 3;
const E_OVERFLOW: u64 = 4;
const E_SNAPSHOT_TOO_EARLY: u64 = 5;
const E_ZERO_SHARES: u64 = 6;
const E_ZERO_USDC_OUT: u64 = 7;
const E_INSUFFICIENT_SHARES: u64 = 8;
const E_INVALID_PLAN: u64 = 9;
const E_REQUEST_NOT_READY: u64 = 10;
const E_NOT_OWNER: u64 = 11;
const E_TREASURY_INSUFFICIENT: u64 = 12;
const E_CYCLE_TOO_EARLY: u64 = 13;
const E_ADAPTER_NOT_IMPLEMENTED: u64 = 14;
const E_CONFIG_FROZEN: u64 = 15;
const E_OBJECT_MISMATCH: u64 = 16;
const E_MISSING_OBJECT: u64 = 17;

public fun e_only_unwind(): u64 { E_ONLY_UNWIND }
public fun e_zero_amount(): u64 { E_ZERO_AMOUNT }
public fun e_div_by_zero(): u64 { E_DIV_BY_ZERO }
public fun e_overflow(): u64 { E_OVERFLOW }
public fun e_snapshot_too_early(): u64 { E_SNAPSHOT_TOO_EARLY }
public fun e_zero_shares(): u64 { E_ZERO_SHARES }
public fun e_zero_usdc_out(): u64 { E_ZERO_USDC_OUT }
public fun e_insufficient_shares(): u64 { E_INSUFFICIENT_SHARES }
public fun e_invalid_plan(): u64 { E_INVALID_PLAN }
public fun e_request_not_ready(): u64 { E_REQUEST_NOT_READY }
public fun e_not_owner(): u64 { E_NOT_OWNER }
public fun e_treasury_insufficient(): u64 { E_TREASURY_INSUFFICIENT }
public fun e_cycle_too_early(): u64 { E_CYCLE_TOO_EARLY }
public fun e_adapter_not_implemented(): u64 { E_ADAPTER_NOT_IMPLEMENTED }
public fun e_config_frozen(): u64 { E_CONFIG_FROZEN }
public fun e_object_mismatch(): u64 { E_OBJECT_MISMATCH }
public fun e_missing_object(): u64 { E_MISSING_OBJECT }
