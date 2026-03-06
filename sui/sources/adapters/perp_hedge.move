module self_driving_yield::perp_hedge;

use self_driving_yield::config;
use self_driving_yield::math;

const INITIAL_MARGIN_BPS: u64 = 500;

/// Returns true when a perps market id is configured (P2).
public fun is_available(cfg: &config::Config): bool {
    config::perps_market_id(cfg) != @0x0
}

public fun initial_margin_bps(): u64 { INITIAL_MARGIN_BPS }

public fun required_margin(size_usdc: u64): u64 {
    math::mul_div(size_usdc, INITIAL_MARGIN_BPS, 10000)
}

/// Open a deterministic accounting short position sized in base-asset USD notionals.
/// Returns (position_id, margin_required).
public fun open_short(cfg: &config::Config, size_usdc: u64): (address, u64) {
    if (!is_available(cfg) || size_usdc == 0) {
        (@0x0, 0)
    } else {
        (config::perps_market_id(cfg), required_margin(size_usdc))
    }
}

/// Close an accounting short and release its entire reserved margin.
public fun close_short(_cfg: &config::Config, position_id: address, current_margin: u64): (address, u64) {
    let next_position = if (position_id == @0x0) { @0x0 } else { @0x0 };
    (next_position, current_margin)
}

/// Adjust a short's target size; returns (next_position_id, next_margin, changed?).
public fun adjust_position(
    cfg: &config::Config,
    position_id: address,
    new_size_usdc: u64,
): (address, u64, bool) {
    if (!is_available(cfg) || new_size_usdc == 0) {
        (@0x0, 0, position_id != @0x0)
    } else {
        let next_position = if (position_id == @0x0) { config::perps_market_id(cfg) } else { position_id };
        (next_position, required_margin(new_size_usdc), true)
    }
}

/// Returns the tracked accounting margin value of the hedge leg.
public fun get_hedge_value(_cfg: &config::Config, current_margin: u64): u64 {
    current_margin
}
