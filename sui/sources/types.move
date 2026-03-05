module self_driving_yield::types;

public enum Regime has copy, drop, store {
    Calm,
    Normal,
    Storm,
}

public fun regime_calm(): Regime { Regime::Calm }
public fun regime_normal(): Regime { Regime::Normal }
public fun regime_storm(): Regime { Regime::Storm }

public fun is_regime_calm(r: &Regime): bool {
    match (r) {
        Regime::Calm => true,
        _ => false,
    }
}

public fun is_regime_normal(r: &Regime): bool {
    match (r) {
        Regime::Normal => true,
        _ => false,
    }
}

public fun is_regime_storm(r: &Regime): bool {
    match (r) {
        Regime::Storm => true,
        _ => false,
    }
}

public enum RiskMode has copy, drop, store {
    Normal,
    OnlyUnwind,
}

public fun risk_normal(): RiskMode { RiskMode::Normal }
public fun risk_only_unwind(): RiskMode { RiskMode::OnlyUnwind }

public fun is_only_unwind(m: &RiskMode): bool {
    match (m) {
        RiskMode::OnlyUnwind => true,
        _ => false,
    }
}

/// Allocation in basis points: (yield, lp, buffer).
public fun get_allocation(regime: &Regime): (u64, u64, u64) {
    match (regime) {
        Regime::Calm => (4000, 5700, 300),
        Regime::Normal => (6000, 3700, 300),
        Regime::Storm => (8000, 1700, 300),
    }
}
