module formal::oracle_proofs;

#[spec_only]
use prover::prover::{requires, ensures};

use self_driving_yield::oracle;
use self_driving_yield::types;

#[spec_only(inv_target = self_driving_yield::oracle::OracleState)]
public fun oracle_state_inv(self: &oracle::OracleState): bool {
    if (oracle::snapshot_count(self) == 0) {
        oracle::snapshots_len(self) == 0
            &&
        oracle::last_snapshot_ts_ms(self) == 0
            && oracle::current_twap(self) == 0
            && oracle::current_volatility_bps(self) == 0
            && types::is_regime_normal(&oracle::current_regime(self))
    } else {
        true
    }
}

#[spec(prove)]
fun compute_regime_cold_start_forces_normal_spec(sample_count: u64, volatility_bps: u64): types::Regime {
    requires(sample_count < oracle::min_samples());
    let result = oracle::compute_regime(sample_count, volatility_bps);
    ensures(types::is_regime_normal(&result));
    result
}

#[spec(prove)]
fun compute_regime_calm_range_spec(sample_count: u64, volatility_bps: u64): types::Regime {
    requires(sample_count >= oracle::min_samples());
    requires(volatility_bps < 100);
    let result = oracle::compute_regime(sample_count, volatility_bps);
    ensures(types::is_regime_calm(&result));
    result
}

#[spec(prove)]
fun compute_regime_normal_range_spec(sample_count: u64, volatility_bps: u64): types::Regime {
    requires(sample_count >= oracle::min_samples());
    requires(volatility_bps >= 100);
    requires(volatility_bps < 300);
    let result = oracle::compute_regime(sample_count, volatility_bps);
    ensures(types::is_regime_normal(&result));
    result
}

#[spec(prove)]
fun compute_regime_storm_range_spec(sample_count: u64, volatility_bps: u64): types::Regime {
    requires(sample_count >= oracle::min_samples());
    requires(volatility_bps >= 300);
    let result = oracle::compute_regime(sample_count, volatility_bps);
    ensures(types::is_regime_storm(&result));
    result
}

#[spec(prove, target = self_driving_yield::oracle::record_snapshot_with_ts)]
fun first_snapshot_transition_spec(s: &mut oracle::OracleState, price: u64, ts_ms: u64, min_interval_ms: u64): bool {
    requires(price > 0);
    requires(oracle::snapshot_count(s) == 0);
    requires(oracle::snapshots_len(s) == 0);
    requires(oracle::last_snapshot_ts_ms(s) == 0);
    requires(oracle::current_twap(s) == 0);
    requires(oracle::current_volatility_bps(s) == 0);
    requires(types::is_regime_normal(&oracle::current_regime(s)));

    let result = oracle::record_snapshot_with_ts(s, price, ts_ms, min_interval_ms);

    ensures(result);
    ensures(oracle::snapshot_count(s) == 1);
    ensures(oracle::snapshots_len(s) == 1);
    ensures(oracle::last_snapshot_ts_ms(s) == ts_ms);
    result
}
