module self_driving_yield::yield_source;

use self_driving_yield::config;
use self_driving_yield::errors;
use sui::coin;

/// Returns true when a lending market id is configured (P2).
public fun is_available(cfg: &config::Config): bool {
    config::lending_market_id(cfg) != @0x0
}

/// P2 adapter interface (not implemented in this repo snapshot).
public fun stake_sui_for_lst<SUI, LST>(
    _cfg: &config::Config,
    _sui_in: coin::Coin<SUI>,
    _ctx: &mut TxContext,
): coin::Coin<LST> {
    abort errors::e_adapter_not_implemented()
}

/// P2 adapter interface (not implemented in this repo snapshot).
public fun unstake_lst<SUI, LST>(
    _cfg: &config::Config,
    _lst_in: coin::Coin<LST>,
    _ctx: &mut TxContext,
): coin::Coin<SUI> {
    abort errors::e_adapter_not_implemented()
}

/// P2 adapter interface (not implemented in this repo snapshot).
public fun deposit_to_lending<BASE>(
    _cfg: &config::Config,
    _base_in: coin::Coin<BASE>,
    _ctx: &mut TxContext,
): address {
    abort errors::e_adapter_not_implemented()
}

/// P2 adapter interface (not implemented in this repo snapshot).
public fun withdraw_from_lending<BASE>(
    _cfg: &config::Config,
    _receipt_id: address,
    _ctx: &mut TxContext,
): coin::Coin<BASE> {
    abort errors::e_adapter_not_implemented()
}

/// P2 adapter interface (not implemented in this repo snapshot).
public fun get_yield_value(_cfg: &config::Config, _receipt_id: address): u64 {
    abort errors::e_adapter_not_implemented()
}
