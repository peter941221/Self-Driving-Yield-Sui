#!/usr/bin/env python3
import argparse
import datetime
import json
import os
import re
import subprocess
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PACKAGE_PATH = ROOT / "sui"


def resolve_cmd(cmd):
    if cmd and cmd[0] == "sui" and os.environ.get("SUI_BIN"):
        return [os.environ["SUI_BIN"], *cmd[1:]]
    return cmd


def run(cmd, cwd=ROOT):
    resolved = resolve_cmd(list(cmd))
    result = subprocess.run(resolved, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "unknown error"
        raise SystemExit(f"Command failed: {' '.join(resolved)}\n{message}")
    return result.stdout.strip()


def try_run(cmd, cwd=ROOT):
    resolved = resolve_cmd(list(cmd))
    result = subprocess.run(resolved, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        return None
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
    return run(["sui", "client", "objects", address])


def find_owned_object_id_by_type(payload, type_fragment):
    if isinstance(payload, str):
        pattern = re.compile(
            r"objectId\s*│\s*(0x[a-fA-F0-9]+).*?version\s*│\s*(\d+).*?objectType\s*│\s*([^\r\n]+)",
            re.DOTALL,
        )
        candidates = []
        for object_id, version, object_type in pattern.findall(payload):
            if type_fragment in object_type:
                candidates.append((int(version), object_id))
        if not candidates:
            raise SystemExit(f"Unable to find owned object type containing: {type_fragment}")
        candidates.sort(reverse=True)
        return candidates[0][1]

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


def normalize_address(value):
    if not isinstance(value, str) or not value.startswith("0x"):
        raise SystemExit(f"Expected hex address, got: {value}")
    hex_part = value[2:]
    if not hex_part:
        raise SystemExit(f"Expected non-empty hex address, got: {value}")
    try:
        int(hex_part, 16)
    except ValueError as exc:
        raise SystemExit(f"Invalid hex address: {value}") from exc
    if len(hex_part) > 64:
        raise SystemExit(f"Address too long: {value}")
    return "0x" + hex_part.lower().zfill(64)


def utc_now_iso():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()


def current_git_commit():
    output = try_run(["git", "rev-parse", "HEAD"])
    return output or ""


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


def load_published_package_id(package_path, env_name):
    published_path = package_path / "Published.toml"
    if not published_path.exists():
        return None
    try:
        payload = tomllib.loads(published_path.read_text(encoding="utf-8"))
    except Exception:
        return None
    return payload.get("published", {}).get(env_name, {}).get("published-at")


def backup_and_remove_published_file(package_path):
    published_path = package_path / "Published.toml"
    if not published_path.exists():
        return None
    backup_dir = ROOT / "out" / "published_backups"
    backup_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    backup_path = backup_dir / f"Published.{timestamp}.toml"
    backup_path.write_text(published_path.read_text(encoding="utf-8"), encoding="utf-8")
    published_path.unlink()
    return backup_path


def main():
    parser = argparse.ArgumentParser(description="Publish, initialize, configure, and seal the Self-Driving Yield Sui package")
    parser.add_argument("--base-type", required=True, help="Base asset type tag, e.g. 0xdba3...::usdc::USDC")
    parser.add_argument("--package-path", default=str(DEFAULT_PACKAGE_PATH), help="Path to the Move package")
    parser.add_argument("--min-cycle-interval-ms", type=int, default=0)
    parser.add_argument("--min-snapshot-interval-ms", type=int, default=0)
    parser.add_argument("--pilot-bootstrap", action="store_true", help="Use entrypoints::bootstrap_pilot to enable operator gating + deposit guardrails from the first shared-object state")
    parser.add_argument("--pilot-operator", default="", help="Operator address for Route A pilot gating (default: sender)")
    parser.add_argument("--pilot-max-total-assets", type=int, default=0, help="TVL cap for deposits (0 means no cap)")
    parser.add_argument("--pilot-allowlist-enabled", type=int, default=1, help="1/0: require allowlisted depositor addresses when enabled")
    parser.add_argument("--pilot-deposits-paused", type=int, default=1, help="1/0: pause deposits at bootstrap (recommended for pilot until allowlist is configured)")
    parser.add_argument("--pilot-allowlist", action="append", default=[], help="Repeatable allowlist address to add via AdminCap after bootstrap")
    parser.add_argument("--cetus-pool-id", default="0x0")
    parser.add_argument("--lending-market-id", default="0x0")
    parser.add_argument("--perps-market-id", default="0x0")
    parser.add_argument("--flashloan-provider-id", default="0x0")
    parser.add_argument("--gas-budget-publish", type=int, default=300_000_000)
    parser.add_argument("--gas-budget-call", type=int, default=80_000_000)
    parser.add_argument("--manifest-out", default="", help="Output JSON manifest path (default: out/deployments/<env>.json)")
    parser.add_argument("--skip-seal", action="store_true", help="Leave Config mutable after initialization")
    parser.add_argument("--force-publish", action="store_true", help="Ignore Published.toml and publish a fresh package using an ephemeral pubfile")
    args = parser.parse_args()

    env_name = active_env()
    sender = active_address()
    package_path = Path(args.package_path).resolve()
    manifest_path = Path(args.manifest_out) if args.manifest_out else ROOT / "out" / "deployments" / f"{env_name}.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)

    print_step("env", env_name)
    print_step("sender", sender)

    publish_digest = None
    package_id = None if args.force_publish else load_published_package_id(package_path, env_name)
    if package_id:
        print_step("published", f"reusing package={package_id} from Published.toml")
    else:
        if args.force_publish:
            backup_path = backup_and_remove_published_file(package_path)
            if backup_path:
                print_step("publish mode", f"force-publish after backing up {backup_path}")
        publish_cmd = [
            "sui", "client", "publish", ".",
            "--build-env", env_name,
            "--gas-budget", str(args.gas_budget_publish),
            "--json",
        ]
        publish_payload = run_json(publish_cmd, cwd=package_path)
        publish_digest = extract_digest(publish_payload)
        published_tx = tx_block(publish_digest)
        package_id = find_package_id(published_tx)
        print_step("published", f"package={package_id} digest={publish_digest}")

    owned_objects = list_owned_objects(sender)
    sdye_treasury_id = find_owned_object_id_by_type(owned_objects, f"TreasuryCap<{package_id}::sdye::SDYE>")
    print_step("sdye treasury", sdye_treasury_id)

    bootstrap_function = "bootstrap"
    bootstrap_args = [sdye_treasury_id, args.min_cycle_interval_ms, args.min_snapshot_interval_ms]
    pilot_operator = ""
    if args.pilot_bootstrap:
        bootstrap_function = "bootstrap_pilot"
        pilot_operator = normalize_address(args.pilot_operator) if args.pilot_operator else normalize_address(sender)
        bootstrap_args.extend([
            pilot_operator,
            int(args.pilot_max_total_assets),
            int(args.pilot_allowlist_enabled),
            int(args.pilot_deposits_paused),
        ])
        print_step("pilot bootstrap", f"operator={pilot_operator} allowlist_enabled={int(args.pilot_allowlist_enabled)} deposits_paused={int(args.pilot_deposits_paused)} max_total_assets={int(args.pilot_max_total_assets)}")

    bootstrap_digest, bootstrap_tx = move_call(
        package_id,
        "entrypoints",
        bootstrap_function,
        bootstrap_args,
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

    if args.pilot_bootstrap and args.pilot_allowlist:
        for raw_addr in args.pilot_allowlist:
            addr = normalize_address(raw_addr)
            digest, _ = move_call(
                package_id,
                "entrypoints",
                "pilot_add_allowlist_address_entry",
                [vault_id, admin_cap_id, addr],
                type_args=[args.base_type],
                gas_budget=args.gas_budget_call,
            )
            print_step("pilot allowlist add", f"{addr} digest={digest}")

    setters = [
        ("set_cetus_pool_id", normalize_address(args.cetus_pool_id)),
        ("set_lending_market_id", normalize_address(args.lending_market_id)),
        ("set_perps_market_id", normalize_address(args.perps_market_id)),
        ("set_flashloan_provider_id", normalize_address(args.flashloan_provider_id)),
    ]
    applied = {}
    for function_name, value in setters:
        if int(value, 16) == 0:
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

    manifest_timestamp = utc_now_iso()
    normalized_cetus_pool_id = setters[0][1]
    normalized_lending_market_id = setters[1][1]
    normalized_perps_market_id = setters[2][1]
    normalized_flashloan_provider_id = setters[3][1]
    sealed = not args.skip_seal

    seal_digest = None
    if sealed:
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
        "published_at_utc": manifest_timestamp,
        "git_commit": current_git_commit(),
        "min_cycle_interval_ms": args.min_cycle_interval_ms,
        "min_snapshot_interval_ms": args.min_snapshot_interval_ms,
        "pilot": {
            "enabled": bool(args.pilot_bootstrap),
            "operator": pilot_operator,
            "max_total_assets": int(args.pilot_max_total_assets),
            "allowlist_enabled": int(args.pilot_allowlist_enabled),
            "deposits_paused": int(args.pilot_deposits_paused),
            "allowlist": [normalize_address(a) for a in args.pilot_allowlist] if args.pilot_allowlist else [],
        },
        "cetus_pool_id": normalized_cetus_pool_id,
        "lending_market_id": normalized_lending_market_id,
        "perps_market_id": normalized_perps_market_id,
        "flashloan_provider_id": normalized_flashloan_provider_id,
        "sealed": sealed,
        "config": {
            "min_cycle_interval_ms": args.min_cycle_interval_ms,
            "min_snapshot_interval_ms": args.min_snapshot_interval_ms,
            "cetus_pool_id": normalized_cetus_pool_id,
            "lending_market_id": normalized_lending_market_id,
            "perps_market_id": normalized_perps_market_id,
            "flashloan_provider_id": normalized_flashloan_provider_id,
            "sealed": sealed,
        },
        "applied_setters": applied,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2))
    print_step("manifest", manifest_path)
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
