#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PENDING_RESERVE_HAIRCUT_BPS = 5000
QUEUE_PRESSURE_LOW_BPS = 1000
QUEUE_PRESSURE_MEDIUM_BPS = 2500
QUEUE_PRESSURE_HIGH_BPS = 5000
BUFFER_EXTRA_LOW_BPS = 100
BUFFER_EXTRA_MEDIUM_BPS = 250
BUFFER_EXTRA_HIGH_BPS = 500
MAX_ADJUSTED_BUFFER_BPS = 1200
EMERGENCY_BUFFER_FLOOR_USDC = 300


def adjusted_buffer_bps(base_buffer_bps, total_assets, queued_need):
    if total_assets == 0 or queued_need == 0:
        return base_buffer_bps
    queue_pressure_bps = (queued_need * 10000) // total_assets
    if queue_pressure_bps >= QUEUE_PRESSURE_HIGH_BPS:
        extra = BUFFER_EXTRA_HIGH_BPS
    elif queue_pressure_bps >= QUEUE_PRESSURE_MEDIUM_BPS:
        extra = BUFFER_EXTRA_MEDIUM_BPS
    elif queue_pressure_bps >= QUEUE_PRESSURE_LOW_BPS:
        extra = BUFFER_EXTRA_LOW_BPS
    else:
        extra = 0
    return min(MAX_ADJUSTED_BUFFER_BPS, base_buffer_bps + extra)


def reserve_metrics(total_assets, ready, pending, regime_code):
    base_buffer_bps = 300
    weighted_pending = (pending * PENDING_RESERVE_HAIRCUT_BPS) // 10000
    queue_component = ready + weighted_pending
    adjusted_buffer = adjusted_buffer_bps(base_buffer_bps, total_assets, ready + pending)
    buffer_component = (total_assets * adjusted_buffer) // 10000 if total_assets else 0
    floor_component = min(total_assets, EMERGENCY_BUFFER_FLOOR_USDC)
    reserve_target = max(queue_component, buffer_component, floor_component)
    q_score_bps = (queue_component * 10000) // total_assets if total_assets else 0
    deployable = max(0, total_assets - reserve_target)
    return {
        "base_buffer_bps": base_buffer_bps,
        "adjusted_buffer_bps": adjusted_buffer,
        "queue_component": queue_component,
        "buffer_component": buffer_component,
        "floor_component": floor_component,
        "reserve_target": reserve_target,
        "deployable": deployable,
        "q_score_bps": q_score_bps,
        "regime_code": regime_code,
    }


def run(cmd):
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "unknown error"
        raise SystemExit(f"Command failed: {' '.join(cmd)}\n{message}")
    return result.stdout.strip()


def active_rpc_url():
    table = run(["sui", "client", "envs"])
    for line in table.splitlines():
        if "│" not in line or "alias" in line or "─" in line:
            continue
        parts = [part.strip() for part in line.split("│") if part.strip()]
        if len(parts) >= 3 and parts[-1] == "*":
            return parts[1]
    raise SystemExit("Unable to infer active RPC URL from `sui client envs`")


def rpc_call(url, method, params):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        body = json.load(response)
    if "error" in body:
        raise SystemExit(f"RPC error: {body['error']}")
    return body["result"]


def load_manifest(path):
    return json.loads(Path(path).read_text())


def query_module_events(url, package_id, module_name, limit):
    return rpc_call(
        url,
        "suix_queryEvents",
        [{"MoveModule": {"package": package_id, "module": module_name}}, None, limit, True],
    ).get("data", [])


def event_name(event_type):
    return event_type.split("::")[-1]


def format_age_ms(timestamp_ms):
    age_seconds = max(0, int(time.time() - (int(timestamp_ms) / 1000)))
    minutes, seconds = divmod(age_seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}h{minutes}m{seconds}s"
    if minutes:
        return f"{minutes}m{seconds}s"
    return f"{seconds}s"


def main():
    parser = argparse.ArgumentParser(description="Summarize Self-Driving Yield monitoring events and derive operator alerts")
    parser.add_argument("--manifest", required=True, help="Deployment manifest written by scripts/deploy_sui.py")
    parser.add_argument("--rpc-url", default="", help="Override fullnode RPC URL")
    parser.add_argument("--limit", type=int, default=50, help="How many recent events to inspect")
    parser.add_argument("--max-minutes-without-cycle", type=int, default=30)
    args = parser.parse_args()

    manifest = load_manifest(args.manifest)
    rpc_url = args.rpc_url or active_rpc_url()
    events = query_module_events(rpc_url, manifest["package_id"], "entrypoints", args.limit)
    events += query_module_events(rpc_url, manifest["package_id"], "config", args.limit)
    events.sort(key=lambda item: int(item.get("timestampMs", "0")), reverse=True)

    if not events:
        print("ALERT: no events found for package", manifest["package_id"])
        sys.exit(1)

    counts = {}
    latest_cycle = None
    for item in events:
        name = event_name(item.get("type", "unknown"))
        counts[name] = counts.get(name, 0) + 1
        if name == "CycleEvent" and latest_cycle is None:
            latest_cycle = item

    print("Monitoring Summary")
    print("├─ Package:", manifest["package_id"])
    print("├─ Network:", manifest.get("network", "unknown"))
    print("├─ RPC:", rpc_url)
    print("└─ Event counts:", json.dumps(counts, ensure_ascii=False))

    alerts = []
    if latest_cycle is None:
        alerts.append("CRIT: no CycleEvent observed yet")
    else:
        parsed = latest_cycle.get("parsedJson", {})
        timestamp_ms = latest_cycle.get("timestampMs", "0")
        age_minutes = max(0, (time.time() - (int(timestamp_ms) / 1000)) / 60) if timestamp_ms else 10**9
        print("\nLatest Cycle")
        print("├─ Age:", format_age_ms(timestamp_ms))
        print("├─ Spot price:", parsed.get("spot_price"))
        print("├─ Moved USDC:", parsed.get("moved_usdc"))
        print("├─ Bounty USDC:", parsed.get("bounty_usdc"))
        print("├─ Regime code:", parsed.get("regime_code"), "(0=CALM,1=NORMAL,2=STORM)")
        print("├─ OnlyUnwind:", parsed.get("only_unwind"))
        print("├─ Safe cycles:", parsed.get("safe_cycles_since_storm"))
        print("├─ Treasury:", parsed.get("treasury_usdc"))
        print("├─ Deployed:", parsed.get("deployed_usdc"))
        print("├─ Ready queue:", parsed.get("ready_usdc"))
        print("├─ Pending queue:", parsed.get("pending_usdc"))
        print("└─ Used flash:", parsed.get("used_flash"))

        if age_minutes > args.max_minutes_without_cycle:
            alerts.append(f"HIGH: no cycle for {age_minutes:.1f} minutes")
        if parsed.get("only_unwind"):
            alerts.append("HIGH: vault is in OnlyUnwind mode")
        treasury = int(parsed.get("treasury_usdc", 0))
        ready = int(parsed.get("ready_usdc", 0))
        pending = int(parsed.get("pending_usdc", 0))
        total_assets = int(parsed.get("total_assets", 0))
        metrics = reserve_metrics(total_assets, ready, pending, int(parsed.get("regime_code", 1)))
        print("\nReserve Model")
        print("├─ Queue score bps:", metrics["q_score_bps"])
        print("├─ Queue component:", metrics["queue_component"])
        print("├─ Buffer component:", metrics["buffer_component"])
        print("├─ Floor component:", metrics["floor_component"])
        print("├─ Reserve target:", metrics["reserve_target"])
        print("└─ Deployable:", metrics["deployable"])
        if ready > treasury:
            alerts.append("CRIT: ready withdrawals exceed treasury liquidity")
        elif pending > treasury:
            alerts.append("WARN: pending withdrawals exceed treasury liquidity")
        if treasury < metrics["reserve_target"]:
            alerts.append("WARN: treasury sits below derived reserve target")
        if parsed.get("used_flash"):
            alerts.append("INFO: latest rebalance used flash path")

    print("\nAlert Tree")
    if alerts:
        print("├─ " + "\n├─ ".join(alerts))
    else:
        print("└─ OK: no alert thresholds triggered")


if __name__ == "__main__":
    main()
