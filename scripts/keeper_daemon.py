#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import cetus_live_suite as suite
import fetch_spot_price as price_feed


ROOT = Path(__file__).resolve().parents[1]
MONITOR_SCRIPT = Path(__file__).resolve().with_name("monitor_sui.py")
DEFAULT_CLOCK_ID = "0x6"
DEFAULT_POLL_SECONDS = 60
DEFAULT_MIN_TOTAL_GAS_MIST = 2_000_000_000
DEFAULT_GAS_BUDGET = 120_000_000
DEFAULT_PRICE_SCALE = 1_000_000_000


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def load_manifest(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def resolve_cmd(cmd):
    if cmd and cmd[0] == "sui" and os.environ.get("SUI_BIN"):
        return [os.environ["SUI_BIN"], *cmd[1:]]
    return cmd


def run(cmd, cwd=ROOT):
    resolved = resolve_cmd(list(cmd))
    result = subprocess.run(resolved, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "unknown error"
        raise RuntimeError(f"Command failed: {' '.join(str(part) for part in resolved)}\n{message}")
    return result.stdout.strip()


def run_json(cmd, cwd=ROOT):
    output = run(cmd, cwd=cwd)
    try:
        return json.loads(output)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Expected JSON output from {' '.join(str(part) for part in cmd)} but got:\n{output}") from exc


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


def gas_summary():
    payload = run_json(["sui", "client", "gas", "--json"])
    balances = {}
    for item in walk_dicts(payload):
        coin_id = item.get("gasCoinId") or item.get("coinObjectId") or item.get("objectId")
        balance = item.get("mistBalance") or item.get("balance")
        if not isinstance(coin_id, str):
            continue
        try:
            amount = int(balance)
        except Exception:
            amount = 0
        balances[coin_id] = max(amount, balances.get(coin_id, 0))
    if not balances:
        return {"coin_id": "", "largest_mist": 0, "total_mist": 0}
    largest_mist, largest_coin_id = max((amount, coin_id) for coin_id, amount in balances.items())
    return {
        "coin_id": largest_coin_id,
        "largest_mist": largest_mist,
        "total_mist": sum(balances.values()),
    }


def active_env():
    return run(["sui", "client", "active-env"])


def active_address():
    return run(["sui", "client", "active-address"])


def non_zero_address(value):
    if not isinstance(value, str) or not value.startswith("0x"):
        return False
    try:
        return int(value, 16) != 0
    except ValueError:
        return False


def fetch_monitor_payload(args):
    cmd = [
        sys.executable,
        str(MONITOR_SCRIPT),
        "--manifest",
        str(args.manifest),
        "--limit",
        str(args.limit),
        "--max-minutes-without-cycle",
        str(args.max_minutes_without_cycle),
        "--json",
    ]
    if args.rpc_url:
        cmd.extend(["--rpc-url", args.rpc_url])
    return run_json(cmd)


def price_source_args(args):
    return argparse.Namespace(
        source=args.price_source,
        coingecko_id=args.coingecko_id,
        vs_currency=args.vs_currency,
        binance_symbol=args.binance_symbol,
        http_json_url=args.http_json_url,
        http_json_path=args.http_json_path,
        price_scale=args.price_scale,
        timeout_seconds=args.price_timeout_seconds,
    )


def resolve_spot_price(args, monitor_payload):
    if args.spot_price is not None:
        return int(args.spot_price), "static_arg"
    if args.spot_price_command:
        result = subprocess.run(args.spot_price_command, cwd=ROOT, capture_output=True, text=True, shell=True)
        if result.returncode != 0:
            message = result.stderr.strip() or result.stdout.strip() or "unknown error"
            raise RuntimeError(f"spot price command failed: {message}")
        text = result.stdout.strip().splitlines()
        if not text:
            raise RuntimeError("spot price command returned empty output")
        return int(text[-1].strip()), "external_command"
    if args.price_source:
        payload = price_feed.fetch_price(price_source_args(args))
        return int(payload["spot_price"]), payload["source"]
    latest_cycle = monitor_payload.get("latest_cycle") or {}
    if latest_cycle.get("spot_price") is not None:
        return int(latest_cycle["spot_price"]), "latest_cycle_event"
    raise RuntimeError("No spot price source available; pass --spot-price, --spot-price-command, or an external --price-source")


def choose_cycle_mode(args, manifest, monitor_payload):
    if args.mode in ("cycle", "cycle-live"):
        return args.mode
    metrics = monitor_payload.get("metrics", {})
    if (
        non_zero_address(manifest.get("cetus_pool_id") or manifest.get("config", {}).get("cetus_pool_id"))
        and metrics.get("queue_pressure_bps", 0) >= args.live_queue_pressure_bps
        and (metrics.get("ready_usdc", 0) > 0 or metrics.get("pending_usdc", 0) > 0)
    ):
        return "cycle-live"
    return "cycle"


def decide_action(args, monitor_payload):
    reasons = []
    metrics = monitor_payload.get("metrics", {})
    summary = monitor_payload.get("summary", {})
    if not summary.get("latest_cycle_seen"):
        reasons.append("no_cycle_event")
    if metrics.get("latest_cycle_age_minutes", 0) > args.max_minutes_without_cycle:
        reasons.append("stale_cycle")
    if metrics.get("only_unwind"):
        reasons.append("only_unwind")
    if metrics.get("reserve_gap_usdc", 0) > args.reserve_gap_threshold:
        reasons.append("reserve_gap")
    if metrics.get("queue_pressure_bps", 0) >= args.queue_pressure_bps_trigger:
        reasons.append("queue_pressure")
    return reasons


def execute_cycle(manifest, spot_price, gas_budget, clock_id):
    payload = run_json([
        "sui", "client", "call",
        "--package", manifest["package_id"],
        "--module", "entrypoints",
        "--function", "cycle_entry",
        "--type-args", manifest["base_type"],
        "--args",
        manifest["vault_id"],
        manifest["queue_id"],
        manifest["config_id"],
        str(spot_price),
        clock_id,
        "--gas-budget", str(gas_budget),
        "--json",
    ])
    digest = extract_digest(payload)
    return {"mode": "cycle", "digest": digest, "tx_block": tx_block(digest)}


def execute_cycle_live(manifest, spot_price, gas_budget, clock_id, cetus_global_config_id):
    current_sdye_type = suite.sdye_type(manifest["package_id"])
    pool_id = manifest.get("cetus_pool_id") or manifest.get("config", {}).get("cetus_pool_id", "0x0")
    payload = run_json([
        "sui", "client", "call",
        "--package", manifest["package_id"],
        "--module", "cetus_live",
        "--function", "cycle_live_entry",
        "--type-args", manifest["base_type"], suite.DEFAULT_QUOTE_TYPE, current_sdye_type,
        "--args",
        manifest["vault_id"],
        manifest["queue_id"],
        manifest["config_id"],
        cetus_global_config_id,
        pool_id,
        str(spot_price),
        clock_id,
        "--gas-budget", str(gas_budget),
        "--json",
    ])
    digest = extract_digest(payload)
    return {"mode": "cycle-live", "digest": digest, "tx_block": tx_block(digest)}


def summarize_events(tx_block_payload):
    summary = {"cycle_event": None, "close_event": None}
    for event in tx_block_payload.get("events", []):
        event_type = str(event.get("type", ""))
        if event_type.endswith("::entrypoints::CycleEvent"):
            summary["cycle_event"] = event.get("parsedJson", {})
        elif event_type.endswith("::cetus_live::CetusPositionClosedEvent"):
            summary["close_event"] = event.get("parsedJson", {})
    return summary


def append_jsonl(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload) + "\n")


def acquire_lock(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
    fd = os.open(str(path), flags)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(json.dumps({"pid": os.getpid(), "created_at_utc": utc_now()}, indent=2))


def release_lock(path):
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def default_lockfile(manifest_path):
    return ROOT / "out" / "locks" / f"keeper_{Path(manifest_path).stem}.lock"


def main():
    parser = argparse.ArgumentParser(description="Poll monitor_sui.py and optionally execute cycle_entry / cycle_live_entry from a local keeper loop")
    parser.add_argument("--manifest", required=True, help="Deployment manifest written by scripts/deploy_sui.py")
    parser.add_argument("--rpc-url", default="", help="Override fullnode RPC URL passed into monitor_sui.py")
    parser.add_argument("--mode", choices=("auto", "cycle", "cycle-live"), default="auto")
    parser.add_argument("--poll-seconds", type=int, default=DEFAULT_POLL_SECONDS)
    parser.add_argument("--once", action="store_true", help="Evaluate once and exit")
    parser.add_argument("--max-iterations", type=int, default=0, help="Stop after N iterations; 0 means unlimited")
    parser.add_argument("--limit", type=int, default=50, help="How many recent events to inspect per monitor call")
    parser.add_argument("--max-minutes-without-cycle", type=int, default=30)
    parser.add_argument("--queue-pressure-bps-trigger", type=int, default=1000)
    parser.add_argument("--live-queue-pressure-bps", type=int, default=1000)
    parser.add_argument("--reserve-gap-threshold", type=int, default=0)
    parser.add_argument("--spot-price", type=int, default=None, help="Static spot price passed to cycle calls")
    parser.add_argument("--spot-price-command", default="", help="Command that prints an integer spot price")
    parser.add_argument("--price-source", choices=("coingecko", "binance", "http-json"), default="", help="Fetch the spot price from an external HTTP JSON source")
    parser.add_argument("--coingecko-id", default="sui")
    parser.add_argument("--vs-currency", default="usd")
    parser.add_argument("--binance-symbol", default="SUIUSDT")
    parser.add_argument("--http-json-url", default="")
    parser.add_argument("--http-json-path", default="")
    parser.add_argument("--price-scale", type=int, default=DEFAULT_PRICE_SCALE)
    parser.add_argument("--price-timeout-seconds", type=int, default=20)
    parser.add_argument("--clock-id", default=DEFAULT_CLOCK_ID)
    parser.add_argument("--gas-budget", type=int, default=DEFAULT_GAS_BUDGET)
    parser.add_argument("--min-total-gas-mist", type=int, default=DEFAULT_MIN_TOTAL_GAS_MIST)
    parser.add_argument("--cetus-global-config-id", default=suite.DEFAULT_CETUS_GLOBAL_CONFIG_ID)
    parser.add_argument("--execute", action="store_true", help="Actually submit cycle transactions; otherwise dry-run only")
    parser.add_argument("--lockfile", default="", help="Override the lockfile path")
    parser.add_argument("--log-out", default=str(ROOT / "out" / "reports" / "keeper_daemon.jsonl"))
    parser.add_argument("--backoff-max-seconds", type=int, default=900)
    args = parser.parse_args()

    manifest = load_manifest(args.manifest)
    lockfile = Path(args.lockfile) if args.lockfile else default_lockfile(args.manifest)
    log_path = Path(args.log_out)

    try:
        acquire_lock(lockfile)
    except FileExistsError:
        raise SystemExit(f"keeper lock already exists: {lockfile}")

    iteration = 0
    failure_count = 0
    try:
        while True:
            iteration += 1
            record = {
                "timestamp_utc": utc_now(),
                "iteration": iteration,
                "manifest": str(Path(args.manifest).resolve()),
                "env": active_env(),
                "address": active_address(),
                "execute": bool(args.execute),
            }
            try:
                monitor_payload = fetch_monitor_payload(args)
                gas = gas_summary()
                reasons = decide_action(args, monitor_payload)
                record["monitor"] = monitor_payload
                record["gas"] = gas
                record["reasons"] = reasons

                if gas["total_mist"] < args.min_total_gas_mist:
                    record["status"] = "blocked_low_gas"
                    record["action_hint"] = "Fund the keeper wallet before expecting automatic cycle calls."
                elif not reasons:
                    record["status"] = "idle"
                    record["action_hint"] = "No trigger conditions were met."
                else:
                    spot_price, price_source = resolve_spot_price(args, monitor_payload)
                    mode = choose_cycle_mode(args, manifest, monitor_payload)
                    record["selected_mode"] = mode
                    record["spot_price"] = spot_price
                    record["price_source"] = price_source
                    if not args.execute:
                        record["status"] = "dry_run_ready"
                        record["action_hint"] = "Run again with --execute to submit the selected cycle path."
                    else:
                        if mode == "cycle-live":
                            result = execute_cycle_live(manifest, spot_price, args.gas_budget, args.clock_id, args.cetus_global_config_id)
                        else:
                            result = execute_cycle(manifest, spot_price, args.gas_budget, args.clock_id)
                        record["status"] = "executed"
                        record["tx"] = {
                            "mode": result["mode"],
                            "digest": result["digest"],
                            "event_summary": summarize_events(result["tx_block"]),
                        }
                        record["action_hint"] = "Transaction submitted successfully."
                failure_count = 0
            except Exception as exc:
                failure_count += 1
                delay = min(args.backoff_max_seconds, args.poll_seconds * (2 ** max(0, failure_count - 1)))
                record["status"] = "failed"
                record["error"] = str(exc)
                record["backoff_seconds"] = delay
                record["action_hint"] = "Inspect the error, RPC health, gas wallet, and lockfile state."

            append_jsonl(log_path, record)
            print(json.dumps(record, indent=2))

            if args.once or (args.max_iterations and iteration >= args.max_iterations):
                return

            if record["status"] == "failed":
                time.sleep(record["backoff_seconds"])
            else:
                time.sleep(args.poll_seconds)
    finally:
        release_lock(lockfile)


if __name__ == "__main__":
    main()
