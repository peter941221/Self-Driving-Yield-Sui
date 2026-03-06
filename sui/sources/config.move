module self_driving_yield::config;

public struct AdminCap has key, store {
    id: UID,
}

public struct Config has key, store {
    id: UID,
    min_cycle_interval_ms: u64,
    min_snapshot_interval_ms: u64,
    // Adapter configuration (P2). Use 0x0 to represent "unset / disabled".
    cetus_pool_id: address,
    lending_market_id: address,
    perps_market_id: address,
    flashloan_provider_id: address,
}

public fun new(
    min_cycle_interval_ms: u64,
    min_snapshot_interval_ms: u64,
    ctx: &mut TxContext
): (Config, AdminCap) {
    let cfg = Config {
        id: object::new(ctx),
        min_cycle_interval_ms,
        min_snapshot_interval_ms,
        cetus_pool_id: @0x0,
        lending_market_id: @0x0,
        perps_market_id: @0x0,
        flashloan_provider_id: @0x0,
    };
    let cap = AdminCap { id: object::new(ctx) };
    (cfg, cap)
}

public fun min_cycle_interval_ms(cfg: &Config): u64 {
    cfg.min_cycle_interval_ms
}

public fun min_snapshot_interval_ms(cfg: &Config): u64 {
    cfg.min_snapshot_interval_ms
}

public fun cetus_pool_id(cfg: &Config): address { cfg.cetus_pool_id }
public fun lending_market_id(cfg: &Config): address { cfg.lending_market_id }
public fun perps_market_id(cfg: &Config): address { cfg.perps_market_id }
public fun flashloan_provider_id(cfg: &Config): address { cfg.flashloan_provider_id }

public fun set_min_cycle_interval_ms(cfg: &mut Config, _cap: &AdminCap, v: u64) {
    cfg.min_cycle_interval_ms = v;
}

public fun set_min_snapshot_interval_ms(cfg: &mut Config, _cap: &AdminCap, v: u64) {
    cfg.min_snapshot_interval_ms = v;
}

public fun set_cetus_pool_id(cfg: &mut Config, _cap: &AdminCap, v: address) {
    cfg.cetus_pool_id = v;
}

public fun set_lending_market_id(cfg: &mut Config, _cap: &AdminCap, v: address) {
    cfg.lending_market_id = v;
}

public fun set_perps_market_id(cfg: &mut Config, _cap: &AdminCap, v: address) {
    cfg.perps_market_id = v;
}

public fun set_flashloan_provider_id(cfg: &mut Config, _cap: &AdminCap, v: address) {
    cfg.flashloan_provider_id = v;
}
