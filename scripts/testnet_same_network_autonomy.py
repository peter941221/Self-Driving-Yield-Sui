#!/usr/bin/env python3
import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

import cetus_cycle_live_probe as cycle_probe
import cetus_live_suite as suite
import sui_staking_probe as staking_probe


ROOT = Path(__file__).resolve().parents[1]
SYSTEM_STATE_ID = "0x5"


def find_event(tx_block, suffix):
    for item in tx_block.get("events", []):
        if str(item.get("type", "")).endswith(suffix):
            return item
    raise SystemExit(f"Unable to find event ending with {suffix}")


def choose_validator(preferred=""):
    return staking_probe.choose_validator(preferred)


def largest_gas_coin_id():
    payload = staking_probe.run_json(["sui", "client", "gas", "--json"])
    if not payload:
        raise SystemExit("No gas coins available")
    best = max(payload, key=lambda item: int(item.get("mistBalance", 0)))
    return best["gasCoinId"]


def ensure_manifest(manifest_path, refresh, force_publish, pool_id, lending_market_id):
    manifest_path = Path(manifest_path)
    if manifest_path.exists() and not refresh:
        return json.loads(manifest_path.read_text(encoding="utf-8"))
    cmd = [
        "python", "scripts/deploy_sui.py",
        "--base-type", "0x2::sui::SUI",
        "--min-cycle-interval-ms", "0",
        "--min-snapshot-interval-ms", "0",
        "--cetus-pool-id", pool_id,
        "--lending-market-id", lending_market_id,
        "--gas-budget-publish", "350000000",
        "--gas-budget-call", "120000000",
        "--manifest-out", str(manifest_path),
    ]
    if force_publish:
        cmd.append("--force-publish")
    suite.run(cmd)
    return json.loads(manifest_path.read_text(encoding="utf-8"))


def call_entry(package_id, function, manifest, *args, gas_budget="120000000"):
    digest, _ = suite.call_json_with_digest([
        "sui", "client", "call",
        "--package", package_id,
        "--module", "entrypoints",
        "--function", function,
        "--type-args", manifest["base_type"],
        "--args", *[str(arg) for arg in args],
        "--gas-budget", str(gas_budget),
        "--json",
    ])
    return digest, suite.tx_block(digest)


def run_stake(stake_amount, validator, gas_budget):
    gas_coin_id = largest_gas_coin_id()
    payload = staking_probe.run_json([
        "sui", "client", "ptb",
        "--split-coins", "gas", f"[{stake_amount}]",
        "--assign", "STAKE",
        "--move-call", "0x3::sui_system::request_add_stake", f"@{SYSTEM_STATE_ID}", "STAKE.0", f"@{validator}",
        "--gas", gas_coin_id,
        "--gas-budget", str(gas_budget),
        "--json",
    ])
    digest = payload["digest"]
    event = next(item for item in payload.get("events", []) if str(item.get("type", "")).endswith("::validator::StakingRequestEvent"))
    staked_sui = next(item for item in payload.get("objectChanges", []) if item.get("type") == "created" and str(item.get("objectType", "")).endswith("::staking_pool::StakedSui"))
    return {
        "digest": digest,
        "gas_coin_id": gas_coin_id,
        "staking_event": event.get("parsedJson", {}),
        "staked_sui_object_id": staked_sui.get("objectId"),
    }


def main():
    parser = argparse.ArgumentParser(description="Run a same-network testnet operator loop that combines cycle planning, a real Cetus position, and a real native staking yield leg with on-chain bookkeeping sync")
    parser.add_argument("--manifest", default=str(ROOT / "out" / "deployments" / "testnet_same_network_autonomy.json"))
    parser.add_argument("--refresh-manifest", action="store_true")
    parser.add_argument("--force-publish", action="store_true")
    parser.add_argument("--deposit-amount", type=int, default=500_000_000)
    parser.add_argument("--open-amount", type=int, default=25_000_000)
    parser.add_argument("--stake-amount", type=int, default=1_000_000_000)
    parser.add_argument("--spot-price", type=int, default=1_000_000_000)
    parser.add_argument("--tick-lower", type=int, default=-200)
    parser.add_argument("--tick-upper", type=int, default=200)
    parser.add_argument("--validator", default="")
    parser.add_argument("--existing-staked-sui-id", default="")
    parser.add_argument("--reuse-existing-state", action="store_true", help="Skip fresh deposit/open and reuse the current vault live state for sync + cycle evidence")
    parser.add_argument("--clock-id", default=suite.DEFAULT_CLOCK_ID)
    parser.add_argument("--report-out", default="")
    args = parser.parse_args()

    if suite.active_env() != "testnet":
        raise SystemExit(f"Expected active env testnet, got {suite.active_env()}")

    validator = choose_validator(args.validator)
    manifest = ensure_manifest(args.manifest, args.refresh_manifest, args.force_publish, suite.DEFAULT_CETUS_POOL_ID, validator)
    report_path = Path(args.report_out) if args.report_out else ROOT / "out" / "reports" / f"testnet_same_network_autonomy_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)

    report = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "env": suite.active_env(),
        "address": suite.active_address(),
        "manifest": str(Path(args.manifest)),
        "validator": validator,
        "status": "started",
        "steps": [],
    }

    if not args.reuse_existing_state:
        deposit = cycle_probe.deposit_and_get_share_coin(manifest, args.deposit_amount, args.clock_id)
        report["steps"].append({"step": "deposit_entry", **deposit})

        cycle1 = cycle_probe.run_plain_cycle(manifest, args.spot_price, args.clock_id)
        cycle1_tx = suite.tx_block(cycle1["digest"])
        cycle1_plan = find_event(cycle1_tx, "::entrypoints::StrategyPlannedEvent").get("parsedJson", {})
        report["steps"].append({"step": "cycle_entry_plan_1", **cycle1, "strategy_plan": cycle1_plan})

        live_open = cycle_probe.open_live_position(manifest, args.open_amount, args.tick_lower, args.tick_upper, args.clock_id)
        report["steps"].append({"step": "open_position_into_vault_entry", **live_open})

    if args.existing_staked_sui_id:
        stake = {
            "digest": "reused",
            "gas_coin_id": "reused",
            "staking_event": {},
            "staked_sui_object_id": args.existing_staked_sui_id,
        }
    else:
        stake = run_stake(args.stake_amount, validator, 120_000_000)
    report["steps"].append({"step": "native_stake", **stake})

    sync_deposit_digest, sync_deposit_tx = call_entry(
        manifest["package_id"],
        "sync_live_yield_deposit_entry",
        manifest,
        manifest["vault_id"],
        manifest["config_id"],
        manifest["admin_cap_id"],
        stake["staked_sui_object_id"],
        args.stake_amount,
        args.stake_amount,
        args.clock_id,
    )
    report["steps"].append({
        "step": "sync_live_yield_deposit_entry",
        "digest": sync_deposit_digest,
        "effects": sync_deposit_tx.get("effects", {}).get("status", {}),
    })

    sync_hold_digest, sync_hold_tx = call_entry(
        manifest["package_id"],
        "sync_live_yield_hold_entry",
        manifest,
        manifest["vault_id"],
        manifest["config_id"],
        manifest["admin_cap_id"],
        stake["staked_sui_object_id"],
        args.stake_amount,
        args.clock_id,
    )
    report["steps"].append({
        "step": "sync_live_yield_hold_entry",
        "digest": sync_hold_digest,
        "effects": sync_hold_tx.get("effects", {}).get("status", {}),
    })

    cycle2 = cycle_probe.run_plain_cycle(manifest, args.spot_price, args.clock_id)
    cycle2_tx = suite.tx_block(cycle2["digest"])
    cycle2_plan = find_event(cycle2_tx, "::entrypoints::StrategyPlannedEvent").get("parsedJson", {})
    cycle2_event = find_event(cycle2_tx, "::entrypoints::CycleEvent").get("parsedJson", {})
    report["steps"].append({
        "step": "cycle_entry_plan_2",
        **cycle2,
        "strategy_plan": cycle2_plan,
        "cycle_event": cycle2_event,
    })

    report["status"] = "ok"
    report["what_it_proves"] = "A same-network testnet operator loop can combine planner-driven cycle execution, a real vault-held Cetus live position, and a real native staking yield leg with on-chain bookkeeping sync."
    report["what_it_does_not_prove"] = "This probe still uses an operator loop between planner output and live protocol calls, and the perps hedge leg remains disabled because a real testnet venue is not yet available."
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
