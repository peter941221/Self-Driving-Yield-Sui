#!/usr/bin/env python3
import argparse
import json
import subprocess
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RPC_URL = "https://fullnode.testnet.sui.io:443"
SYSTEM_STATE_ID = "0x5"


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


def rpc_call(method, params):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = urllib.request.Request(RPC_URL, data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        body = json.load(response)
    if "error" in body:
        raise SystemExit(f"RPC error: {body['error']}")
    return body["result"]


def active_address():
    return run(["sui", "client", "active-address"])


def choose_validator(preferred=""):
    if preferred:
        return preferred
    state = rpc_call("suix_getLatestSuiSystemState", [])
    validators = state.get("activeValidators", [])
    if not validators:
        raise SystemExit("No active validators returned by suix_getLatestSuiSystemState")
    return validators[0]["suiAddress"]


def main():
    parser = argparse.ArgumentParser(description="Run a real testnet Sui staking transaction as the current yield-source probe and archive a JSON report")
    parser.add_argument("--stake-amount", type=int, default=1_000_000_000, help="Stake amount in MIST; default = 1 SUI")
    parser.add_argument("--validator", default="", help="Optional validator Sui address; defaults to the first active validator")
    parser.add_argument("--gas-budget", type=int, default=120_000_000)
    parser.add_argument("--report-out", default="")
    args = parser.parse_args()

    validator = choose_validator(args.validator)
    report_path = Path(args.report_out) if args.report_out else ROOT / "out" / "reports" / f"sui_staking_probe_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)

    payload = run_json([
        "sui", "client", "ptb",
        "--split-coins", "gas", f"[{args.stake_amount}]",
        "--assign", "STAKE",
        "--move-call", "0x3::sui_system::request_add_stake", f"@{SYSTEM_STATE_ID}", "STAKE.0", f"@{validator}",
        "--gas-budget", str(args.gas_budget),
        "--json",
    ])

    digest = payload["digest"]
    event = next(item for item in payload.get("events", []) if str(item.get("type", "")).endswith("::validator::StakingRequestEvent"))
    staked_sui = next(item for item in payload.get("objectChanges", []) if item.get("type") == "created" and str(item.get("objectType", "")).endswith("::staking_pool::StakedSui"))

    report = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "env": "testnet",
        "address": active_address(),
        "status": payload.get("effects", {}).get("status", {}),
        "digest": digest,
        "validator": validator,
        "stake_amount_mist": args.stake_amount,
        "staking_event": event.get("parsedJson", {}),
        "staked_sui_object_id": staked_sui.get("objectId"),
    }
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
