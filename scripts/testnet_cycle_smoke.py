#!/usr/bin/env python3
import argparse
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CLOCK_ID = "0x6"
DEFAULT_BASE_TYPE = "0x2::sui::SUI"
DEFAULT_PRICE_SERIES = [100_000, 100_500, 101_200, 102_800, 103_500, 101_000, 99_500, 98_800, 100_100, 101_700, 103_200, 100_300]


def run(cmd, cwd=ROOT):
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "unknown error"
        raise RuntimeError(f"Command failed: {' '.join(cmd)}\n{message}")
    return result.stdout.strip()


def run_json(cmd, cwd=ROOT):
    output = run(cmd, cwd=cwd)
    try:
        return json.loads(output)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Expected JSON from {' '.join(cmd)} but got:\n{output}") from exc


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
    raise RuntimeError("Unable to find transaction digest in CLI JSON output")


def tx_block(digest):
    return run_json(["sui", "client", "tx-block", digest, "--json"])


def active_env():
    return run(["sui", "client", "active-env"])


def active_address():
    return run(["sui", "client", "active-address"])


def largest_gas_coin():
    payload = run_json(["sui", "client", "gas", "--json"])
    candidates = []
    for item in walk_dicts(payload):
        coin_id = item.get("gasCoinId") or item.get("coinObjectId") or item.get("objectId")
        mist = item.get("mistBalance") or item.get("balance")
        if isinstance(coin_id, str):
            try:
                amount = int(mist)
            except Exception:
                amount = 0
            candidates.append((amount, coin_id))
    if not candidates:
        return None, 0
    candidates.sort(reverse=True)
    return candidates[0][1], candidates[0][0]


def find_created_object_id(payload, type_fragment):
    for item in walk_dicts(payload):
        change_type = item.get("type")
        object_type = item.get("objectType")
        object_id = item.get("objectId") or item.get("object_id")
        if change_type == "created" and isinstance(object_type, str) and type_fragment in object_type and isinstance(object_id, str):
            return object_id
    raise RuntimeError(f"Unable to find created object type containing: {type_fragment}")


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


def move_call(package_id, module, function, args, type_args=None, gas_budget=80_000_000):
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


def query_module_events(package_id, module_name, limit=50):
    envs = run(["sui", "client", "envs"])
    rpc_url = None
    for line in envs.splitlines():
        if "│" not in line or "alias" in line or "─" in line:
            continue
        parts = [part.strip() for part in line.split("│") if part.strip()]
        if len(parts) >= 3 and parts[-1] == "*":
            rpc_url = parts[1]
            break
    if not rpc_url:
        raise RuntimeError("Unable to infer active RPC URL")
    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "suix_queryEvents",
        "params": [{"MoveModule": {"package": package_id, "module": module_name}}, None, limit, True],
    }).encode()
    import urllib.request
    request = urllib.request.Request(rpc_url, data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        body = json.load(response)
    if "error" in body:
        raise RuntimeError(str(body["error"]))
    return body["result"].get("data", [])


def deploy_if_needed(manifest_path, base_type, gas_budget_publish, gas_budget_call):
    if manifest_path.exists():
        return json.loads(manifest_path.read_text())
    cmd = [
        "python", "scripts/deploy_sui.py",
        "--base-type", base_type,
        "--min-cycle-interval-ms", "0",
        "--min-snapshot-interval-ms", "0",
        "--gas-budget-publish", str(gas_budget_publish),
        "--gas-budget-call", str(gas_budget_call),
        "--manifest-out", str(manifest_path),
    ]
    run(cmd, cwd=ROOT)
    return json.loads(manifest_path.read_text())


def main():
    parser = argparse.ArgumentParser(description="Deploy on testnet (or reuse manifest), deposit base coin, and execute 10+ cycle() calls")
    parser.add_argument("--manifest", default=str(ROOT / "out" / "deployments" / "testnet_smoke.json"))
    parser.add_argument("--base-type", default=DEFAULT_BASE_TYPE)
    parser.add_argument("--deposit-amount", type=int, default=200_000_000)
    parser.add_argument("--cycles", type=int, default=12)
    parser.add_argument("--clock-id", default=DEFAULT_CLOCK_ID)
    parser.add_argument("--gas-budget-publish", type=int, default=300_000_000)
    parser.add_argument("--gas-budget-call", type=int, default=80_000_000)
    parser.add_argument("--sleep-seconds", type=int, default=0)
    parser.add_argument("--price-series", default=",".join(str(x) for x in DEFAULT_PRICE_SERIES))
    parser.add_argument("--report-out", default="")
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    report_path = Path(args.report_out) if args.report_out else ROOT / "out" / "reports" / f"testnet_cycle_smoke_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)

    report = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "env": active_env(),
        "address": active_address(),
        "status": "started",
        "steps": [],
    }

    coin_id, balance = largest_gas_coin()
    report["preflight_balance_mist"] = balance
    if not coin_id or balance <= args.deposit_amount + args.gas_budget_publish + args.gas_budget_call * (args.cycles + 3):
        report["status"] = "blocked_no_testnet_gas"
        report["blocker"] = "No funded testnet SUI coin available for publish + deposit + 10+ cycles"
        report_path.write_text(json.dumps(report, indent=2))
        raise SystemExit(f"Blocked: insufficient testnet balance. Report written to {report_path}")

    manifest = deploy_if_needed(manifest_path, args.base_type, args.gas_budget_publish, args.gas_budget_call)
    report["manifest"] = str(manifest_path)
    report["package_id"] = manifest["package_id"]
    report["vault_id"] = manifest["vault_id"]
    report["queue_id"] = manifest["queue_id"]
    report["config_id"] = manifest["config_id"]

    split_digest, split_tx = split_coin(coin_id, args.deposit_amount, args.gas_budget_call)
    deposit_coin_id = find_created_object_id(split_tx, f"Coin<{args.base_type}>")
    report["steps"].append({"step": "split_coin", "digest": split_digest, "deposit_coin_id": deposit_coin_id})

    deposit_digest, _ = move_call(
        manifest["package_id"],
        "entrypoints",
        "deposit",
        [manifest["vault_id"], deposit_coin_id, args.clock_id],
        type_args=[args.base_type],
        gas_budget=args.gas_budget_call,
    )
    report["steps"].append({"step": "deposit", "digest": deposit_digest, "amount_mist": args.deposit_amount})

    prices = [int(x.strip()) for x in args.price_series.split(",") if x.strip()]
    cycle_digests = []
    for index in range(args.cycles):
        spot_price = prices[index % len(prices)]
        cycle_digest, _ = move_call(
            manifest["package_id"],
            "entrypoints",
            "cycle",
            [manifest["vault_id"], manifest["queue_id"], manifest["config_id"], spot_price, args.clock_id],
            type_args=[args.base_type],
            gas_budget=args.gas_budget_call,
        )
        cycle_digests.append(cycle_digest)
        report["steps"].append({"step": f"cycle_{index + 1}", "digest": cycle_digest, "spot_price": spot_price})
        if args.sleep_seconds > 0 and index + 1 < args.cycles:
            time.sleep(args.sleep_seconds)

    events = query_module_events(manifest["package_id"], "entrypoints", limit=max(50, args.cycles + 10))
    cycle_events = [item for item in events if str(item.get("type", "")).endswith("::entrypoints::CycleEvent")]
    report["cycle_event_count"] = len(cycle_events)
    report["cycle_digests"] = cycle_digests
    report["status"] = "ok" if len(cycle_events) >= args.cycles else "warning_incomplete_cycle_events"
    report["latest_cycle_event"] = cycle_events[0].get("parsedJson", {}) if cycle_events else None
    report_path.write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
