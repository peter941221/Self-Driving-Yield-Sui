#!/usr/bin/env python3
import argparse
import json
import math
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLOCK_ID = "0x0000000000000000000000000000000000000000000000000000000000000006"


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


def run_json(cmd, cwd=ROOT):
    output = run(cmd, cwd=cwd)
    try:
        return json.loads(output)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Expected JSON output from {' '.join(cmd)} but got:\n{output}") from exc


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
    return payload


def active_env():
    return run(["sui", "client", "active-env"])


def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def require_manifest_fields(manifest, fields):
    missing = [field for field in fields if not manifest.get(field)]
    if missing:
        raise SystemExit(f"Manifest missing required field(s): {', '.join(missing)}")


def parse_amount(value):
    if value is None:
        return 0
    if isinstance(value, int):
        return value
    return int(math.floor(float(value)))


def first_created_object(report_step, contains):
    for item in report_step.get("relevant_object_ids", {}).get("created", []):
        if contains in str(item.get("objectType", "")):
            return item.get("objectId", "")
    return ""


def main():
    parser = argparse.ArgumentParser(description="Bridge a successful Scallop live report back into Vault live-yield bookkeeping using AdminCap-authorized entrypoints")
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--clock-id", default=CLOCK_ID)
    parser.add_argument("--allow-non-isolated", action="store_true", help="Allow syncing when the wallet already had a pre-existing Scallop lending position before this report")
    parser.add_argument("--gas-budget", type=int, default=50_000_000)
    parser.add_argument("--report-out", default="")
    args = parser.parse_args()

    manifest = load_json(args.manifest)
    report = load_json(args.report)
    require_manifest_fields(manifest, ["network", "package_id", "vault_id", "config_id", "admin_cap_id", "base_type"])
    report_path = Path(args.report_out) if args.report_out else ROOT / "out" / "reports" / f"scallop_core_bridge_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)

    before_value = parse_amount(report.get("query_snapshot_before", {}).get("lending", {}).get("availableWithdrawAmount"))
    after_deposit_value = parse_amount(report.get("query_snapshot_after_deposit", {}).get("lending", {}).get("availableWithdrawAmount"))
    after_withdraw_value = parse_amount(report.get("query_snapshot_after_withdraw", {}).get("lending", {}).get("availableWithdrawAmount"))
    deposit_delta = max(0, after_deposit_value - before_value)
    withdraw_delta = max(0, after_deposit_value - after_withdraw_value)
    deposit_step = report.get("steps", [])[0]
    receipt_id = first_created_object(deposit_step, "scallop_sui::SCALLOP_SUI") or report.get("steps", [])[0].get("digest", "")

    bridge_report = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "manifest": str(Path(args.manifest)),
        "source_report": str(Path(args.report)),
        "bridge_mode": "proof_plus_bridge",
        "manifest_network": manifest.get("network"),
        "report_env": report.get("env"),
        "active_env": active_env(),
        "manifest_ids": {
            "package_id": manifest.get("package_id"),
            "vault_id": manifest.get("vault_id"),
            "config_id": manifest.get("config_id"),
            "admin_cap_id": manifest.get("admin_cap_id"),
            "base_type": manifest.get("base_type"),
        },
        "status": "pending",
        "derived": {
            "before_value": before_value,
            "after_deposit_value": after_deposit_value,
            "after_withdraw_value": after_withdraw_value,
            "deposit_delta": deposit_delta,
            "withdraw_delta": withdraw_delta,
            "receipt_id": receipt_id,
        },
    }

    if report.get("status") != "ok":
        bridge_report["status"] = "blocked_bad_report_status"
        report_path.write_text(json.dumps(bridge_report, indent=2), encoding="utf-8")
        raise SystemExit(f"Blocked: source report status is not ok. Report written to {report_path}")

    if manifest.get("network") != report.get("env"):
        bridge_report["status"] = "blocked_cross_network"
        report_path.write_text(json.dumps(bridge_report, indent=2), encoding="utf-8")
        raise SystemExit(f"Blocked: manifest network {manifest.get('network')} != report env {report.get('env')}. Report written to {report_path}")

    if bridge_report["active_env"] != manifest.get("network"):
        bridge_report["status"] = "blocked_wrong_active_env"
        report_path.write_text(json.dumps(bridge_report, indent=2), encoding="utf-8")
        raise SystemExit(f"Blocked: current active env {bridge_report['active_env']} != manifest network {manifest.get('network')}. Report written to {report_path}")

    if before_value > 0 and not args.allow_non_isolated:
        bridge_report["status"] = "blocked_non_isolated_wallet_state"
        report_path.write_text(json.dumps(bridge_report, indent=2), encoding="utf-8")
        raise SystemExit(f"Blocked: source wallet already had a pre-existing Scallop position before this run. Report written to {report_path}")

    if not receipt_id:
        bridge_report["status"] = "blocked_missing_receipt_id"
        report_path.write_text(json.dumps(bridge_report, indent=2), encoding="utf-8")
        raise SystemExit(f"Blocked: could not derive a Scallop receipt object id from report. Report written to {report_path}")

    payloads = []
    base_type = manifest["base_type"]
    common_args = [manifest["vault_id"], manifest["config_id"], manifest["admin_cap_id"]]
    payloads.append({
        "step": "sync_live_yield_deposit_entry",
        "payload": move_call(
            manifest["package_id"],
            "entrypoints",
            "sync_live_yield_deposit_entry",
            common_args + [receipt_id, deposit_delta, after_deposit_value, args.clock_id],
            type_args=[base_type],
            gas_budget=args.gas_budget,
        ),
    })
    payloads.append({
        "step": "sync_live_yield_hold_entry",
        "payload": move_call(
            manifest["package_id"],
            "entrypoints",
            "sync_live_yield_hold_entry",
            common_args + [receipt_id, after_deposit_value, args.clock_id],
            type_args=[base_type],
            gas_budget=args.gas_budget,
        ),
    })
    payloads.append({
        "step": "sync_live_yield_withdraw_entry",
        "payload": move_call(
            manifest["package_id"],
            "entrypoints",
            "sync_live_yield_withdraw_entry",
            common_args + [receipt_id, withdraw_delta, after_withdraw_value, args.clock_id],
            type_args=[base_type],
            gas_budget=args.gas_budget,
        ),
    })

    bridge_report["status"] = "ok"
    bridge_report["steps"] = payloads
    report_path.write_text(json.dumps(bridge_report, indent=2), encoding="utf-8")
    print(json.dumps(bridge_report, indent=2))


if __name__ == "__main__":
    main()
