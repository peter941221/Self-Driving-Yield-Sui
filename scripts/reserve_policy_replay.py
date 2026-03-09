#!/usr/bin/env python3
import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

import monitor_sui as monitor


ROOT = Path(__file__).resolve().parents[1]


DEFAULT_SCENARIOS = [
    {"name": "steady_state", "treasury_usdc": 700, "ready_usdc": 0, "pending_usdc": 0, "deployed_usdc": 300, "regime_code": 1},
    {"name": "light_queue", "treasury_usdc": 650, "ready_usdc": 80, "pending_usdc": 120, "deployed_usdc": 350, "regime_code": 1},
    {"name": "medium_queue", "treasury_usdc": 500, "ready_usdc": 180, "pending_usdc": 220, "deployed_usdc": 500, "regime_code": 1},
    {"name": "stress_unwind", "treasury_usdc": 300, "ready_usdc": 260, "pending_usdc": 340, "deployed_usdc": 700, "regime_code": 2},
]


def load_scenarios(path):
    if not path:
        return DEFAULT_SCENARIOS
    payload = json.loads(Path(path).read_text(encoding="utf-8"))
    if isinstance(payload, dict):
        return payload.get("scenarios", [])
    if isinstance(payload, list):
        return payload
    raise SystemExit("Scenario file must be a JSON list or an object with a scenarios field")


def infer_total_assets(item):
    if "total_assets" in item:
        return int(item["total_assets"])
    treasury = int(item.get("treasury_usdc", 0))
    deployed = int(item.get("deployed_usdc", 0))
    return treasury + deployed


def action_for(item, metrics, queue_pressure_bps, reserve_gap):
    if int(item.get("ready_usdc", 0)) > int(item.get("treasury_usdc", 0)):
        return "unwind_now"
    if reserve_gap > 0 and int(item.get("regime_code", 1)) >= 2:
        return "only_unwind"
    if reserve_gap > 0:
        return "raise_reserve"
    if queue_pressure_bps >= monitor.QUEUE_PRESSURE_MEDIUM_BPS:
        return "watch_queue"
    if metrics["deployable"] > 0:
        return "deployable"
    return "hold"


def replay_scenario(item):
    total_assets = infer_total_assets(item)
    treasury = int(item.get("treasury_usdc", 0))
    ready = int(item.get("ready_usdc", 0))
    pending = int(item.get("pending_usdc", 0))
    regime_code = int(item.get("regime_code", 1))
    queued_need = ready + pending
    metrics = monitor.reserve_metrics(total_assets, ready, pending, regime_code)
    queue_pressure_bps = (queued_need * 10000) // total_assets if total_assets else 0
    reserve_gap = max(0, metrics["reserve_target"] - treasury)
    return {
        "name": item.get("name", "scenario"),
        "regime_code": regime_code,
        "total_assets": total_assets,
        "treasury_usdc": treasury,
        "deployed_usdc": int(item.get("deployed_usdc", max(0, total_assets - treasury))),
        "ready_usdc": ready,
        "pending_usdc": pending,
        "queue_pressure_bps": queue_pressure_bps,
        "reserve_gap_usdc": reserve_gap,
        "reserve_model": metrics,
        "recommended_action": action_for(item, metrics, queue_pressure_bps, reserve_gap),
    }


def print_text(results):
    print("Reserve Policy Replay")
    for item in results:
        reserve = item["reserve_model"]
        print(f"├─ {item['name']}")
        print(f"│  ├─ regime_code: {item['regime_code']}")
        print(f"│  ├─ total_assets: {item['total_assets']}")
        print(f"│  ├─ treasury / deployed: {item['treasury_usdc']} / {item['deployed_usdc']}")
        print(f"│  ├─ ready / pending: {item['ready_usdc']} / {item['pending_usdc']}")
        print(f"│  ├─ queue_pressure_bps: {item['queue_pressure_bps']}")
        print(f"│  ├─ reserve_target: {reserve['reserve_target']}")
        print(f"│  ├─ reserve_gap_usdc: {item['reserve_gap_usdc']}")
        print(f"│  ├─ deployable: {reserve['deployable']}")
        print(f"│  └─ action: {item['recommended_action']}")


def main():
    parser = argparse.ArgumentParser(description="Replay the current reserve policy against synthetic or file-backed scenarios without touching chain state")
    parser.add_argument("--scenario-file", default="", help="JSON list of scenarios, or object with a scenarios field")
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON")
    parser.add_argument("--report-out", default="", help="Optional JSON output path")
    args = parser.parse_args()

    results = [replay_scenario(item) for item in load_scenarios(args.scenario_file)]
    payload = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "scenario_count": len(results),
        "results": results,
    }

    if args.report_out:
        out = Path(args.report_out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    if args.json:
        print(json.dumps(payload, indent=2))
    else:
        print_text(results)


if __name__ == "__main__":
    main()
