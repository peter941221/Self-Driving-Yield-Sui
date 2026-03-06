#!/usr/bin/env python3
import argparse
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PACKAGE_PATH = ROOT / "sui"


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


def find_package_id(published_tx):
    for item in walk_dicts(published_tx):
        if "packageId" in item and isinstance(item["packageId"], str):
            return item["packageId"]
    raise SystemExit("Unable to find published package id in tx-block output")


def find_object_id_by_type(payload, type_fragment):
    for item in walk_dicts(payload):
        object_type = item.get("objectType")
        object_id = item.get("objectId") or item.get("object_id")
        if isinstance(object_type, str) and type_fragment in object_type and isinstance(object_id, str):
            return object_id
    raise SystemExit(f"Unable to find object type containing: {type_fragment}")


def list_owned_objects(address):
    return run_json(["sui", "client", "objects", address, "--json"])


def find_owned_object_id_by_type(payload, type_fragment):
    candidates = []
    for item in walk_dicts(payload):
        object_type = item.get("type") or item.get("objectType")
        object_id = item.get("objectId") or item.get("object_id")
        version = item.get("version")
        if isinstance(object_type, str) and type_fragment in object_type and isinstance(object_id, str):
            try:
                numeric_version = int(version)
            except Exception:
                numeric_version = 0
            candidates.append((numeric_version, object_id))
    if not candidates:
        raise SystemExit(f"Unable to find owned object type containing: {type_fragment}")
    candidates.sort(reverse=True)
    return candidates[0][1]


def move_call(package_id, module, function, args, type_args=None, gas_budget=50_000_000):
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


def print_step(title, detail):
    print(f"[+] {title}: {detail}")


def main():
    parser = argparse.ArgumentParser(description="Publish, initialize, configure, and seal the Self-Driving Yield Sui package")
    parser.add_argument("--base-type", required=True, help="Base asset type tag, e.g. 0xdba3...::usdc::USDC")
    parser.add_argument("--package-path", default=str(DEFAULT_PACKAGE_PATH), help="Path to the Move package")
    parser.add_argument("--min-cycle-interval-ms", type=int, default=0)
    parser.add_argument("--min-snapshot-interval-ms", type=int, default=0)
    parser.add_argument("--cetus-pool-id", default="0x0")
    parser.add_argument("--lending-market-id", default="0x0")
    parser.add_argument("--perps-market-id", default="0x0")
    parser.add_argument("--flashloan-provider-id", default="0x0")
    parser.add_argument("--gas-budget-publish", type=int, default=300_000_000)
    parser.add_argument("--gas-budget-call", type=int, default=80_000_000)
    parser.add_argument("--manifest-out", default="", help="Output JSON manifest path (default: out/deployments/<env>.json)")
    parser.add_argument("--skip-seal", action="store_true", help="Leave Config mutable after initialization")
    args = parser.parse_args()

    env_name = active_env()
    sender = active_address()
    manifest_path = Path(args.manifest_out) if args.manifest_out else ROOT / "out" / "deployments" / f"{env_name}.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)

    print_step("env", env_name)
    print_step("sender", sender)

    publish_payload = run_json([
        "sui", "client", "publish", str(Path(args.package_path)),
        "--gas-budget", str(args.gas_budget_publish),
        "--json",
    ], cwd=ROOT)
    publish_digest = extract_digest(publish_payload)
    published_tx = tx_block(publish_digest)
    package_id = find_package_id(published_tx)
    print_step("published", f"package={package_id} digest={publish_digest}")

    owned_objects = list_owned_objects(sender)
    sdye_treasury_id = find_owned_object_id_by_type(owned_objects, f"TreasuryCap<{package_id}::sdye::SDYE>")
    print_step("sdye treasury", sdye_treasury_id)

    bootstrap_digest, bootstrap_tx = move_call(
        package_id,
        "entrypoints",
        "bootstrap",
        [sdye_treasury_id, args.min_cycle_interval_ms, args.min_snapshot_interval_ms],
        type_args=[args.base_type],
        gas_budget=args.gas_budget_call,
    )
    print_step("bootstrapped", bootstrap_digest)

    vault_id = find_object_id_by_type(bootstrap_tx, f"{package_id}::entrypoints::Vault<{args.base_type}>")
    queue_id = find_object_id_by_type(bootstrap_tx, f"{package_id}::queue::WithdrawalQueue")
    config_id = find_object_id_by_type(bootstrap_tx, f"{package_id}::config::Config")

    owned_after_bootstrap = list_owned_objects(sender)
    admin_cap_id = find_owned_object_id_by_type(owned_after_bootstrap, f"{package_id}::config::AdminCap")

    print_step("vault", vault_id)
    print_step("queue", queue_id)
    print_step("config", config_id)
    print_step("admin cap", admin_cap_id)

    setters = [
        ("set_cetus_pool_id", args.cetus_pool_id),
        ("set_lending_market_id", args.lending_market_id),
        ("set_perps_market_id", args.perps_market_id),
        ("set_flashloan_provider_id", args.flashloan_provider_id),
    ]
    applied = {}
    for function_name, value in setters:
        if value.lower() == "0x0":
            continue
        digest, _ = move_call(
            package_id,
            "config",
            function_name,
            [config_id, admin_cap_id, value],
            gas_budget=args.gas_budget_call,
        )
        applied[function_name] = {"value": value, "digest": digest}
        print_step(function_name, value)

    seal_digest = None
    if not args.skip_seal:
        seal_digest, _ = move_call(
            package_id,
            "config",
            "seal",
            [config_id, admin_cap_id],
            gas_budget=args.gas_budget_call,
        )
        print_step("config sealed", seal_digest)

    manifest = {
        "network": env_name,
        "sender": sender,
        "base_type": args.base_type,
        "package_id": package_id,
        "vault_id": vault_id,
        "queue_id": queue_id,
        "config_id": config_id,
        "admin_cap_id": admin_cap_id,
        "publish_digest": publish_digest,
        "bootstrap_digest": bootstrap_digest,
        "seal_digest": seal_digest,
        "config": {
            "min_cycle_interval_ms": args.min_cycle_interval_ms,
            "min_snapshot_interval_ms": args.min_snapshot_interval_ms,
            "cetus_pool_id": args.cetus_pool_id,
            "lending_market_id": args.lending_market_id,
            "perps_market_id": args.perps_market_id,
            "flashloan_provider_id": args.flashloan_provider_id,
            "sealed": not args.skip_seal,
        },
        "applied_setters": applied,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2))
    print_step("manifest", manifest_path)
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
