module self_driving_yield::rebalancer;

use self_driving_yield::config;

const FLASH_THRESHOLD_USDC: u64 = 2_500;

/// Returns true when a flash-loan provider id is configured (P2).
public fun is_available(cfg: &config::Config): bool {
    config::flashloan_provider_id(cfg) != @0x0
}

public fun flash_threshold_usdc(): u64 { FLASH_THRESHOLD_USDC }

/// Small rebalances stay on the plain PTB path.
public fun rebalance_ptb(_cfg: &config::Config, delta_usdc: u64): bool {
    delta_usdc > 0 && delta_usdc < FLASH_THRESHOLD_USDC
}

/// Large rebalances switch to the flash-loan path when configured.
public fun rebalance_flash(cfg: &config::Config, delta_usdc: u64): bool {
    is_available(cfg) && delta_usdc >= FLASH_THRESHOLD_USDC
}