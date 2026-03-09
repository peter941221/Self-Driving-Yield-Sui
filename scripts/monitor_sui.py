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
SEVERITY_ORDER = {
    "ok": 0,
    "info": 1,
    "warn": 2,
    "high": 3,
    "crit": 4,
}


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


def build_alert(code, severity, summary, action_hint):
    return {
        "code": code,
        "severity": severity,
        "summary": summary,
        "action_hint": action_hint,
    }


def worst_severity(alerts):
    current = "ok"
    for alert in alerts:
        if SEVERITY_ORDER[alert["severity"]] > SEVERITY_ORDER[current]:
            current = alert["severity"]
    return current


def status_from_severity(severity):
    if severity == "crit":
        return "critical"
    if severity == "high":
        return "degraded"
    if severity == "warn":
        return "warning"
    if severity == "info":
        return "attention"
    return "ok"


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


def round_minutes(value):
    return round(max(0.0, float(value)), 2)


def metrics_from_cycle(parsed, age_minutes, max_minutes_without_cycle):
    treasury = int(parsed.get("treasury_usdc", 0))
    ready = int(parsed.get("ready_usdc", 0))
    pending = int(parsed.get("pending_usdc", 0))
    total_assets = int(parsed.get("total_assets", 0))
    metrics = reserve_metrics(total_assets, ready, pending, int(parsed.get("regime_code", 1)))
    queued_need = ready + pending
    queue_pressure_bps = (queued_need * 10000) // total_assets if total_assets else 0
    reserve_gap = max(0, metrics["reserve_target"] - treasury)
    ready_coverage_bps = (treasury * 10000) // ready if ready > 0 else 10000
    return {
        "latest_cycle_age_minutes": round_minutes(age_minutes),
        "stale_cycle_minutes": round_minutes(age_minutes),
        "max_minutes_without_cycle": max_minutes_without_cycle,
        "queue_pressure_bps": queue_pressure_bps,
        "queued_need_usdc": queued_need,
        "reserve_gap_usdc": reserve_gap,
        "ready_coverage_bps": ready_coverage_bps,
        "treasury_usdc": treasury,
        "ready_usdc": ready,
        "pending_usdc": pending,
        "total_assets": total_assets,
        "deployed_usdc": int(parsed.get("deployed_usdc", 0)),
        "used_flash": bool(parsed.get("used_flash")),
        "only_unwind": bool(parsed.get("only_unwind")),
        "reserve_model": metrics,
    }


def build_monitor_payload(manifest, rpc_url, events, latest_cycle, max_minutes_without_cycle):
    counts = {}
    alerts = []
    for item in events:
        name = event_name(item.get("type", "unknown"))
        counts[name] = counts.get(name, 0) + 1

    payload = {
        "package_id": manifest["package_id"],
        "network": manifest.get("network", "unknown"),
        "rpc_url": rpc_url,
        "event_counts": counts,
        "latest_cycle": None,
        "metrics": {},
        "alerts": [],
        "summary": {"severity": "ok", "status": "ok"},
    }

    if latest_cycle is None:
        alerts.append(build_alert(
            "no_cycle_event",
            "crit",
            "CRIT: no CycleEvent observed yet",
            "Confirm bootstrap completed, then run a first cycle or start the keeper loop.",
        ))
    else:
        parsed = latest_cycle.get("parsedJson", {})
        timestamp_ms = latest_cycle.get("timestampMs", "0")
        age_minutes = max(0, (time.time() - (int(timestamp_ms) / 1000)) / 60) if timestamp_ms else 10**9
        metrics = metrics_from_cycle(parsed, age_minutes, max_minutes_without_cycle)
        payload["latest_cycle"] = {
            "timestamp_ms": timestamp_ms,
            "age_human": format_age_ms(timestamp_ms),
            "spot_price": parsed.get("spot_price"),
            "moved_usdc": parsed.get("moved_usdc"),
            "bounty_usdc": parsed.get("bounty_usdc"),
            "regime_code": parsed.get("regime_code"),
            "only_unwind": parsed.get("only_unwind"),
            "safe_cycles_since_storm": parsed.get("safe_cycles_since_storm"),
            "treasury_usdc": parsed.get("treasury_usdc"),
            "deployed_usdc": parsed.get("deployed_usdc"),
            "ready_usdc": parsed.get("ready_usdc"),
            "pending_usdc": parsed.get("pending_usdc"),
            "used_flash": parsed.get("used_flash"),
            "total_assets": parsed.get("total_assets"),
        }
        payload["metrics"] = metrics

        if age_minutes > max_minutes_without_cycle:
            alerts.append(build_alert(
                "stale_cycle",
                "high",
                f"HIGH: no cycle for {age_minutes:.1f} minutes",
                "Run cycle_entry via a keeper, or investigate gas, RPC, and operator liveness.",
            ))
        if metrics["only_unwind"]:
            alerts.append(build_alert(
                "only_unwind_mode",
                "high",
                "HIGH: vault is in OnlyUnwind mode",
                "Do not re-risk. Prioritize unwind execution and explain the trigger in ops notes.",
            ))
        if metrics["ready_usdc"] > metrics["treasury_usdc"]:
            alerts.append(build_alert(
                "ready_exceeds_treasury",
                "crit",
                "CRIT: ready withdrawals exceed treasury liquidity",
                "Unwind or top up treasury before more claims are encouraged.",
            ))
        elif metrics["pending_usdc"] > metrics["treasury_usdc"]:
            alerts.append(build_alert(
                "pending_exceeds_treasury",
                "warn",
                "WARN: pending withdrawals exceed treasury liquidity",
                "Expect queue pressure to stay elevated; prepare an unwind cycle if it converts to ready.",
            ))
        if metrics["reserve_gap_usdc"] > 0:
            alerts.append(build_alert(
                "reserve_gap",
                "warn",
                "WARN: treasury sits below derived reserve target",
                "Increase ready reserve or reduce deployed exposure until reserve_gap_usdc returns to 0.",
            ))
        if metrics["used_flash"]:
            alerts.append(build_alert(
                "flash_path_used",
                "info",
                "INFO: latest rebalance used flash path",
                "Review whether this was expected; repeated flash usage can signal reserve stress.",
            ))

    severity = worst_severity(alerts)
    payload["alerts"] = alerts
    payload["summary"] = {
        "severity": severity,
        "status": status_from_severity(severity),
        "alert_count": len(alerts),
        "latest_cycle_seen": latest_cycle is not None,
    }
    return payload


def main():
    parser = argparse.ArgumentParser(description="Summarize Self-Driving Yield monitoring events and derive operator alerts")
    parser.add_argument("--manifest", required=True, help="Deployment manifest written by scripts/deploy_sui.py")
    parser.add_argument("--rpc-url", default="", help="Override fullnode RPC URL")
    parser.add_argument("--limit", type=int, default=50, help="How many recent events to inspect")
    parser.add_argument("--max-minutes-without-cycle", type=int, default=30)
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON instead of the text summary")
    parser.add_argument("--json-out", default="", help="Write the machine-readable payload to a JSON file")
    args = parser.parse_args()

    manifest = load_manifest(args.manifest)
    rpc_url = args.rpc_url or active_rpc_url()
    events = query_module_events(rpc_url, manifest["package_id"], "entrypoints", args.limit)
    events += query_module_events(rpc_url, manifest["package_id"], "config", args.limit)
    events.sort(key=lambda item: int(item.get("timestampMs", "0")), reverse=True)

    if not events:
        payload = {
            "package_id": manifest["package_id"],
            "network": manifest.get("network", "unknown"),
            "rpc_url": rpc_url,
            "event_counts": {},
            "latest_cycle": None,
            "metrics": {},
            "alerts": [
                build_alert(
                    "no_events",
                    "crit",
                    f"ALERT: no events found for package {manifest['package_id']}",
                    "Verify the manifest package ID, RPC endpoint, and whether the package has emitted events yet.",
                )
            ],
            "summary": {"severity": "crit", "status": "critical", "alert_count": 1, "latest_cycle_seen": False},
        }
        if args.json_out:
            json_out = Path(args.json_out)
            json_out.parent.mkdir(parents=True, exist_ok=True)
            json_out.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        if args.json:
            print(json.dumps(payload, indent=2))
        else:
            print("ALERT: no events found for package", manifest["package_id"])
        sys.exit(1)

    latest_cycle = None
    for item in events:
        if event_name(item.get("type", "unknown")) == "CycleEvent" and latest_cycle is None:
            latest_cycle = item

    payload = build_monitor_payload(manifest, rpc_url, events, latest_cycle, args.max_minutes_without_cycle)
    if args.json_out:
        json_out = Path(args.json_out)
        json_out.parent.mkdir(parents=True, exist_ok=True)
        json_out.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    if args.json:
        print(json.dumps(payload, indent=2))
        return

    print("Monitoring Summary")
    print("├─ Package:", payload["package_id"])
    print("├─ Network:", payload["network"])
    print("├─ RPC:", payload["rpc_url"])
    print("├─ Status:", payload["summary"]["status"])
    print("├─ Severity:", payload["summary"]["severity"])
    print("└─ Event counts:", json.dumps(payload["event_counts"], ensure_ascii=False))

    latest = payload["latest_cycle"]
    if latest:
        print("\nLatest Cycle")
        print("├─ Age:", latest["age_human"])
        print("├─ Spot price:", latest["spot_price"])
        print("├─ Moved USDC:", latest["moved_usdc"])
        print("├─ Bounty USDC:", latest["bounty_usdc"])
        print("├─ Regime code:", latest["regime_code"], "(0=CALM,1=NORMAL,2=STORM)")
        print("├─ OnlyUnwind:", latest["only_unwind"])
        print("├─ Safe cycles:", latest["safe_cycles_since_storm"])
        print("├─ Treasury:", latest["treasury_usdc"])
        print("├─ Deployed:", latest["deployed_usdc"])
        print("├─ Ready queue:", latest["ready_usdc"])
        print("├─ Pending queue:", latest["pending_usdc"])
        print("└─ Used flash:", latest["used_flash"])

        metrics = payload["metrics"]
        reserve = metrics["reserve_model"]
        print("\nReserve Model")
        print("├─ Queue pressure bps:", metrics["queue_pressure_bps"])
        print("├─ Reserve gap:", metrics["reserve_gap_usdc"])
        print("├─ Queue score bps:", reserve["q_score_bps"])
        print("├─ Queue component:", reserve["queue_component"])
        print("├─ Buffer component:", reserve["buffer_component"])
        print("├─ Floor component:", reserve["floor_component"])
        print("├─ Reserve target:", reserve["reserve_target"])
        print("└─ Deployable:", reserve["deployable"])

    print("\nAlert Tree")
    if payload["alerts"]:
        print("├─ " + "\n├─ ".join(alert["summary"] for alert in payload["alerts"]))
    else:
        print("└─ OK: no alert thresholds triggered")


if __name__ == "__main__":
    main()
