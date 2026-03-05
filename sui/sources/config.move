module self_driving_yield::config;

public struct AdminCap has key, store {
    id: UID,
}

public struct Config has key, store {
    id: UID,
    min_cycle_interval_ms: u64,
    min_snapshot_interval_ms: u64,
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

public fun set_min_cycle_interval_ms(cfg: &mut Config, _cap: &AdminCap, v: u64) {
    cfg.min_cycle_interval_ms = v;
}

public fun set_min_snapshot_interval_ms(cfg: &mut Config, _cap: &AdminCap, v: u64) {
    cfg.min_snapshot_interval_ms = v;
}
