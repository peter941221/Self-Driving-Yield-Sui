module self_driving_yield::perp_hedge;

use self_driving_yield::config;
use self_driving_yield::errors;
use sui::coin;

/// Returns true when a perps market id is configured (P2).
public fun is_available(cfg: &config::Config): bool {
    config::perps_market_id(cfg) != @0x0
}

/// P2 adapter interface (not implemented in this repo snapshot).
public fun open_short<BASE>(
    _cfg: &config::Config,
    _margin_in: coin::Coin<BASE>,
    _size_usdc: u64,
    _ctx: &mut TxContext,
): address {
    abort errors::e_adapter_not_implemented()
}

/// P2 adapter interface (not implemented in this repo snapshot).
public fun close_short<BASE>(
    _cfg: &config::Config,
    _position_id: address,
    _ctx: &mut TxContext,
): coin::Coin<BASE> {
    abort errors::e_adapter_not_implemented()
}

/// P2 adapter interface (not implemented in this repo snapshot).
public fun adjust_position(
    _cfg: &config::Config,
    _position_id: address,
    _new_size_usdc: u64,
): bool {
    abort errors::e_adapter_not_implemented()
}

/// P2 adapter interface (not implemented in this repo snapshot).
public fun get_hedge_value(_cfg: &config::Config, _position_id: address): u64 {
    abort errors::e_adapter_not_implemented()
}
