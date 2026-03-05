module self_driving_yield::events;

public struct DepositEvent has copy, drop, store {
    sender: address,
    assets_in: u64,
    shares_out: u64,
}

public struct WithdrawRequestedEvent has copy, drop, store {
    sender: address,
    request_id: u64,
    shares: u64,
}

