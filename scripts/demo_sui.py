#!/usr/bin/env python3
import argparse
import json
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CLOCK_ID = "0x6"


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


def active_address():
    return run(["sui", "client", "active-address"])


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


def split_coin(coin_id, amount, gas_budget):
    payload = run_json([
        "sui", "client", "split-coin",
        "--coin-id", coin_id,
        "--amounts", str(amount),
        "--gas-budget", str(gas_budget),
        "--json",
    ])
    digest = extract_digest(payload)
    return digest, tx_block(digest)


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


def main():
    parser = argparse.ArgumentParser(description="Run a 5-minute deposit -> cycle -> withdraw -> cycle -> claim demo against a deployed vault")
    parser.add_argument("--manifest", required=True, help="Deployment manifest written by scripts/deploy_sui.py")
    parser.add_argument("--base-coin-id", required=True, help="Owned Coin<BASE> object to split for the deposit")
    parser.add_argument("--deposit-amount", type=int, required=True)
    parser.add_argument("--spot-price-entry", type=int, default=100_000)
    parser.add_argument("--spot-price-exit", type=int, default=100_000)
    parser.add_argument("--clock-id", default=DEFAULT_CLOCK_ID)
    parser.add_argument("--gas-budget", type=int, default=80_000_000)
    parser.add_argument("--wait-between-cycles-seconds", type=int, default=0)
    args = parser.parse_args()

    manifest = json.loads(Path(args.manifest).read_text())
    sender = active_address()
    package_id = manifest["package_id"]
    base_type = manifest["base_type"]
    sdye_type_fragment = f"Coin<{package_id}::sdye::SDYE>"
    base_coin_type_fragment = f"Coin<{base_type}>"

    print("Demo Plan")
    print("├─ Sender:", sender)
    print("├─ Package:", package_id)
    print("├─ Vault:", manifest["vault_id"])
    print("├─ Queue:", manifest["queue_id"])
    print("└─ Config:", manifest["config_id"])

    split_digest, split_tx = split_coin(args.base_coin_id, args.deposit_amount, args.gas_budget)
    deposit_coin_id = find_created_object_id(split_tx, base_coin_type_fragment)
    print("[+] split coin:", deposit_coin_id, split_digest)

    deposit_digest, deposit_tx = move_call(
        package_id,
        "entrypoints",
        "deposit_entry",
        [manifest["vault_id"], deposit_coin_id, args.clock_id],
        type_args=[base_type],
        gas_budget=args.gas_budget,
    )
    share_coin_id = find_created_object_id(deposit_tx, sdye_type_fragment)
    print("[+] deposit minted SDYE:", share_coin_id, deposit_digest)

    cycle1_digest, _ = move_call(
        package_id,
        "entrypoints",
        "cycle_entry",
        [manifest["vault_id"], manifest["queue_id"], manifest["config_id"], args.spot_price_entry, args.clock_id],
        type_args=[base_type],
        gas_budget=args.gas_budget,
    )
    print("[+] cycle #1:", cycle1_digest)

    withdraw_digest, withdraw_tx = move_call(
        package_id,
        "entrypoints",
        "request_withdraw_entry",
        [manifest["vault_id"], manifest["queue_id"], share_coin_id, args.clock_id],
        type_args=[base_type],
        gas_budget=args.gas_budget,
    )
    withdraw_event = find_event(withdraw_tx, "::entrypoints::WithdrawRequestedEvent")
    parsed = withdraw_event.get("parsedJson", {})
    print("[+] withdraw requested:", withdraw_digest, json.dumps(parsed, ensure_ascii=False))

    if not parsed.get("queued", False):
        print("[+] withdrawal was instant; demo ended without claim path")
        return

    if args.wait_between_cycles_seconds > 0:
        print(f"[+] waiting {args.wait_between_cycles_seconds}s before cycle #2")
        time.sleep(args.wait_between_cycles_seconds)

    cycle2_digest, _ = move_call(
        package_id,
        "entrypoints",
        "cycle_entry",
        [manifest["vault_id"], manifest["queue_id"], manifest["config_id"], args.spot_price_exit, args.clock_id],
        type_args=[base_type],
        gas_budget=args.gas_budget,
    )
    print("[+] cycle #2:", cycle2_digest)

    request_id = parsed.get("request_id")
    claim_digest, _ = move_call(
        package_id,
        "entrypoints",
        "claim_entry",
        [manifest["vault_id"], manifest["queue_id"], str(request_id), args.clock_id],
        type_args=[base_type],
        gas_budget=args.gas_budget,
    )
    print("[+] claim:", claim_digest, f"request_id={request_id}")
    print("[+] demo complete")


if __name__ == "__main__":
    main()
