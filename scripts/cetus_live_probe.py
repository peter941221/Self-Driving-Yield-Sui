#!/usr/bin/env python3
import argparse
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CLOCK_ID = "0x6"
DEFAULT_MANIFEST = ROOT / "out" / "deployments" / "testnet_cetus_live.json"


def run(cmd, cwd=ROOT):
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "unknown error"
        raise SystemExit(f"Command failed: {' '.join(cmd)}\n{message}")
    return result.stdout.strip()


def run_json(cmd, cwd=ROOT):
    output = run(cmd, cwd=cwd)
    try:
        return json.loads(output)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Expected JSON output from {' '.join(cmd)} but got:\n{output}") from exc


def walk_dicts(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk_dicts(child)
    elif isinstance(value, list):
        for item in value:
            yield from walk_dicts(item)


def extract_digest(payload):
    for item in walk_dicts(payload):
        for key in ("digest", "transactionDigest", "txDigest"):
            if key in item and isinstance(item[key], str):
                return item[key]
    raise SystemExit("Unable to find transaction digest in CLI JSON output")


def tx_block(digest):
    return run_json(["sui", "client", "tx-block", digest, "--json"])


def active_env():
    return run(["sui", "client", "active-env"])


def active_address():
    return run(["sui", "client", "active-address"])


def move_call(package_id, module, function, args, type_args=None, gas_budget=120_000_000):
    cmd = [
        "sui", "client", "call",
        "--package", package_id,
        "--module", module,
        "--function", function,
    ]
    if type_args:
        cmd.extend(["--type-args", *type_args])
    if args:
        cmd.extend(["--args", *[str(arg) for arg in args]])
    cmd.extend(["--gas-budget", str(gas_budget), "--json"])
    payload = run_json(cmd)
    digest = extract_digest(payload)
    return digest, tx_block(digest)


def find_created_object_id(payload, type_fragment):
    for item in walk_dicts(payload):
        change_type = item.get("type")
        object_type = item.get("objectType")
        object_id = item.get("objectId") or item.get("object_id")
        if change_type == "created" and isinstance(object_type, str) and type_fragment in object_type and isinstance(object_id, str):
            return object_id
    raise SystemExit(f"Unable to find created object type containing: {type_fragment}")


def find_event(payload, event_suffix):
    events = payload.get("events", []) if isinstance(payload, dict) else []
    for item in events:
        event_type = item.get("type")
        if isinstance(event_type, str) and event_type.endswith(event_suffix):
            return item
    raise SystemExit(f"Unable to find event ending with: {event_suffix}")


def normalize_address(value):
    value = value.strip()
    if not value.startswith("0x"):
        value = f"0x{value}"
    return value.lower()


def i32_to_u32_bits(value):
    return value & 0xFFFFFFFF


def load_manifest(path):
    return json.loads(Path(path).read_text())


def deploy_if_needed(args, manifest_path):
    if manifest_path.exists() and not args.refresh_manifest:
        manifest = load_manifest(manifest_path)
        configured_pool = normalize_address(manifest.get("config", {}).get("cetus_pool_id", "0x0"))
        expected_pool = normalize_address(args.cetus_pool_id)
        if configured_pool != expected_pool:
            raise SystemExit(
                f"Existing manifest {manifest_path} is pinned to cetus_pool_id={configured_pool}, "
                f"but this run requested {expected_pool}. Use --refresh-manifest or a fresh --manifest path."
            )
        return manifest

    if not args.base_type:
        raise SystemExit("--base-type is required when creating or refreshing a manifest")

    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "python", "scripts/deploy_sui.py",
        "--base-type", args.base_type,
        "--min-cycle-interval-ms", str(args.min_cycle_interval_ms),
        "--min-snapshot-interval-ms", str(args.min_snapshot_interval_ms),
        "--cetus-pool-id", args.cetus_pool_id,
        "--gas-budget-publish", str(args.gas_budget_publish),
        "--gas-budget-call", str(args.gas_budget_call),
        "--manifest-out", str(manifest_path),
    ]
    if args.force_publish:
        cmd.append("--force-publish")
    run(cmd, cwd=ROOT)
    return load_manifest(manifest_path)


def main():
    parser = argparse.ArgumentParser(description="Deploy a fresh Cetus-configured manifest if needed, then run an open -> optional close live probe against real Cetus shared objects")
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST), help="Fresh manifest path for the Cetus-first live slice")
    parser.add_argument("--base-type", default="", help="Required when creating or refreshing a manifest")
    parser.add_argument("--coin-type-a", required=True, help="Must match the actual generic ordering of the target Cetus pool")
    parser.add_argument("--coin-type-b", required=True, help="Must match the actual generic ordering of the target Cetus pool")
    parser.add_argument("--coin-a-id", required=True, help="Owned Coin<CoinTypeA> object to spend on add-liquidity")
    parser.add_argument("--coin-b-id", required=True, help="Owned Coin<CoinTypeB> object to spend on add-liquidity")
    parser.add_argument("--cetus-global-config-id", required=True, help="Shared Cetus GlobalConfig object ID")
    parser.add_argument("--cetus-pool-id", required=True, help="Shared Cetus Pool object ID; also written into the fresh manifest")
    parser.add_argument("--tick-lower", type=int, required=True, help="Signed lower tick, converted to Cetus u32 bit-pattern")
    parser.add_argument("--tick-upper", type=int, required=True, help="Signed upper tick, converted to Cetus u32 bit-pattern")
    parser.add_argument("--amount", type=int, required=True, help="Liquidity add amount passed into Cetus fix-coin flow")
    parser.add_argument("--fix-amount-b", action="store_true", help="Fix CoinTypeB instead of CoinTypeA")
    parser.add_argument("--skip-close", action="store_true", help="Keep the opened position in the wallet instead of closing immediately")
    parser.add_argument("--clock-id", default=DEFAULT_CLOCK_ID)
    parser.add_argument("--refresh-manifest", action="store_true", help="Redeploy a fresh manifest even if the target file already exists")
    parser.add_argument("--force-publish", action="store_true", help="Fresh-publish the package during the deploy step")
    parser.add_argument("--min-cycle-interval-ms", type=int, default=0)
    parser.add_argument("--min-snapshot-interval-ms", type=int, default=0)
    parser.add_argument("--gas-budget-publish", type=int, default=300_000_000)
    parser.add_argument("--gas-budget-call", type=int, default=120_000_000)
    parser.add_argument("--report-out", default="")
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    report_path = Path(args.report_out) if args.report_out else ROOT / "out" / "reports" / f"cetus_live_probe_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)

    report = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "env": active_env(),
        "address": active_address(),
        "status": "started",
        "manifest": str(manifest_path),
        "steps": [],
        "requested": {
            "coin_type_a": args.coin_type_a,
            "coin_type_b": args.coin_type_b,
            "coin_a_id": args.coin_a_id,
            "coin_b_id": args.coin_b_id,
            "cetus_global_config_id": normalize_address(args.cetus_global_config_id),
            "cetus_pool_id": normalize_address(args.cetus_pool_id),
            "tick_lower": args.tick_lower,
            "tick_upper": args.tick_upper,
            "tick_lower_u32": i32_to_u32_bits(args.tick_lower),
            "tick_upper_u32": i32_to_u32_bits(args.tick_upper),
            "amount": args.amount,
            "fix_amount_a": not args.fix_amount_b,
        },
    }

    manifest = deploy_if_needed(args, manifest_path)
    report["package_id"] = manifest["package_id"]
    report["config_id"] = manifest["config_id"]
    report["manifest_config"] = manifest.get("config", {})
    report["manifest_base_type"] = manifest.get("base_type")
    report["manifest_base_matches_coin_type_a"] = manifest.get("base_type") == args.coin_type_a

    open_digest, open_tx = move_call(
        manifest["package_id"],
        "cetus_live",
        "open_position_with_liquidity_entry",
        [
            manifest["config_id"],
            args.cetus_global_config_id,
            args.cetus_pool_id,
            args.coin_a_id,
            args.coin_b_id,
            i32_to_u32_bits(args.tick_lower),
            i32_to_u32_bits(args.tick_upper),
            args.amount,
            str(not args.fix_amount_b).lower(),
            args.clock_id,
        ],
        type_args=[args.coin_type_a, args.coin_type_b],
        gas_budget=args.gas_budget_call,
    )
    open_event = find_event(open_tx, "::cetus_live::CetusPositionOpenedEvent")
    position_id = open_event.get("parsedJson", {}).get("position_id") or find_created_object_id(open_tx, "::position::Position")
    report["steps"].append({
        "step": "open_position_with_liquidity_entry",
        "digest": open_digest,
        "position_id": position_id,
        "event": open_event.get("parsedJson", {}),
    })

    if args.skip_close:
        report["status"] = "opened_only"
        report["open_position_id"] = position_id
    else:
        close_digest, close_tx = move_call(
            manifest["package_id"],
            "cetus_live",
            "close_position_and_withdraw_entry",
            [
                manifest["config_id"],
                args.cetus_global_config_id,
                args.cetus_pool_id,
                position_id,
                args.clock_id,
            ],
            type_args=[args.coin_type_a, args.coin_type_b],
            gas_budget=args.gas_budget_call,
        )
        close_event = find_event(close_tx, "::cetus_live::CetusPositionClosedEvent")
        report["steps"].append({
            "step": "close_position_and_withdraw_entry",
            "digest": close_digest,
            "position_id": position_id,
            "event": close_event.get("parsedJson", {}),
        })
        report["status"] = "ok"

    report_path.write_text(json.dumps(report, indent=2))

    print("Cetus Live Probe")
    print("├─ Env:", report["env"])
    print("├─ Sender:", report["address"])
    print("├─ Manifest:", manifest_path)
    print("├─ Package:", report["package_id"])
    print("├─ Config:", report["config_id"])
    print("├─ Base type:", report["manifest_base_type"])
    print("├─ CoinTypeA matches base:", report["manifest_base_matches_coin_type_a"])
    print("├─ Pool:", normalize_address(args.cetus_pool_id))
    print("└─ Status:", report["status"])
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
