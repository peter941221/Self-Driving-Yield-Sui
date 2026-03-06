module self_driving_yield::rebalancer;

use self_driving_yield::config;
use self_driving_yield::errors;

/// Returns true when a flash-loan provider id is configured (P2).
public fun is_available(cfg: &config::Config): bool {
    config::flashloan_provider_id(cfg) != @0x0
}

/// P2 adapter interface (not implemented in this repo snapshot).
public fun rebalance_ptb(_cfg: &config::Config, _delta_usdc: u64): bool {
    abort errors::e_adapter_not_implemented()
}

/// P2 adapter interface (not implemented in this repo snapshot).
public fun rebalance_flash(_cfg: &config::Config, _delta_usdc: u64): bool {
    abort errors::e_adapter_not_implemented()
}
