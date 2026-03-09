#!/usr/bin/env python3
import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

import cetus_cycle_live_probe as cycle_probe
import cetus_live_suite as suite


ROOT = Path(__file__).resolve().parents[1]


def ensure_manifest(manifest_path, refresh, force_publish, pool_id):
    return suite.ensure_vault_manifest(manifest_path, refresh, force_publish, pool_id)


def parse_existing_share_ids(raw_value):
    return [item.strip() for item in str(raw_value).split(",") if item.strip()]


def main():
    parser = argparse.ArgumentParser(description="Run a real testnet queue-pressure load probe with repeated deposits, queued withdrawals, and cycle/cycle_live execution")
    parser.add_argument("--manifest", default=str(ROOT / "out" / "deployments" / "testnet_pressure_run.json"))
    parser.add_argument("--refresh-manifest", action="store_true")
    parser.add_argument("--force-publish", action="store_true")
    parser.add_argument("--deposit-amount", type=int, default=250_000_000)
    parser.add_argument("--deposit-count", type=int, default=4)
    parser.add_argument("--open-amount", type=int, default=25_000_000)
    parser.add_argument("--existing-share-coin-id", default="", help="Single share coin id or a comma-separated list when --reuse-existing-state is used")
    parser.add_argument("--reuse-existing-state", action="store_true", help="Skip fresh deposit/open and reuse an existing vault state plus share coin to create pressure")
    parser.add_argument("--spot-price", type=int, default=1_000_000_000)
    parser.add_argument("--tick-lower", type=int, default=-200)
    parser.add_argument("--tick-upper", type=int, default=200)
    parser.add_argument("--clock-id", default=suite.DEFAULT_CLOCK_ID)
    parser.add_argument("--report-out", default="")
    args = parser.parse_args()

    if suite.active_env() != "testnet":
        raise SystemExit(f"Expected active env testnet, got {suite.active_env()}")

    manifest = ensure_manifest(args.manifest, args.refresh_manifest, args.force_publish, suite.DEFAULT_CETUS_POOL_ID)
    report_path = Path(args.report_out) if args.report_out else ROOT / "out" / "reports" / f"testnet_pressure_run_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)

    report = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "env": suite.active_env(),
        "address": suite.active_address(),
        "manifest": str(Path(args.manifest)),
        "reuse_existing_state": args.reuse_existing_state,
        "status": "started",
        "steps": [],
    }

    withdraw_steps = []
    share_coin_ids = []
    actual_deposit_count = 0
    if args.reuse_existing_state:
        existing_share_ids = parse_existing_share_ids(args.existing_share_coin_id)
        if args.deposit_count <= 0 and not existing_share_ids:
            raise SystemExit("--existing-share-coin-id or a positive --deposit-count is required when --reuse-existing-state is used")
        for index in range(args.deposit_count):
            deposit = cycle_probe.deposit_and_get_share_coin(manifest, args.deposit_amount, args.clock_id)
            share_coin_ids.append(deposit["share_coin_id"])
            report["steps"].append({"step": f"deposit_entry_reused_state_{index}", **deposit})
        actual_deposit_count = len(share_coin_ids)
        share_coin_ids.extend(existing_share_ids)
        for index, share_coin_id in enumerate(share_coin_ids):
            withdraw = cycle_probe.request_queued_withdraw(
                manifest,
                share_coin_id,
                args.clock_id,
                require_queued=False,
            )
            withdraw_steps.append(withdraw)
            report["steps"].append({"step": f"request_withdraw_entry_reused_state_{index}", **withdraw})
    else:
        deposits = []
        for index in range(args.deposit_count):
            deposit = cycle_probe.deposit_and_get_share_coin(manifest, args.deposit_amount, args.clock_id)
            deposits.append(deposit)
            report["steps"].append({"step": f"deposit_entry_{index}", **deposit})
        actual_deposit_count = len(deposits)

        cycle_before = cycle_probe.run_plain_cycle(manifest, args.spot_price, args.clock_id)
        report["steps"].append({"step": "cycle_entry_before_pressure", **cycle_before})

        live_open = cycle_probe.open_live_position(
            manifest,
            args.open_amount,
            args.tick_lower,
            args.tick_upper,
            args.clock_id,
            exclude_sdye_coin_ids=[deposit["share_coin_id"] for deposit in deposits],
        )
        report["steps"].append({"step": "open_position_into_vault_entry", **live_open})

        for index, deposit in enumerate(deposits):
            withdraw = cycle_probe.request_queued_withdraw(
                manifest,
                deposit["share_coin_id"],
                args.clock_id,
                require_queued=False,
            )
            withdraw_steps.append(withdraw)
            report["steps"].append({"step": f"request_withdraw_entry_{index}", **withdraw})

    queued_withdraws = [step for step in withdraw_steps if step.get("withdraw_event", {}).get("queued", False)]
    if not queued_withdraws:
        raise SystemExit("Expected at least one queued withdrawal before cycle_live probe, but all withdraws were instant")

    cycle_live = cycle_probe.run_cycle_live(manifest, args.spot_price, args.clock_id)
    report["steps"].append({"step": "cycle_live_entry_under_pressure", **cycle_live})

    series = [args.spot_price, args.spot_price + 5_000_000, args.spot_price - 5_000_000, args.spot_price + 2_500_000]
    for index, price in enumerate(series):
        cycle_after = cycle_probe.run_plain_cycle(manifest, price, args.clock_id)
        report["steps"].append({"step": f"cycle_entry_post_pressure_{index}", **cycle_after})

    report["status"] = "ok"
    report["summary"] = {
        "deposit_count": actual_deposit_count,
        "queued_requests": len(withdraw_steps),
        "queued_request_count": len(queued_withdraws),
        "first_live_close_digest": cycle_live["digest"],
        "close_before_cycle": cycle_live.get("close_event_index", 999) < cycle_live.get("cycle_event_index", -1),
    }
    if args.reuse_existing_state:
        report["what_it_proves"] = "The sealed testnet vault can take an additional queued withdrawal on top of its current live state, close the stored real Cetus position under pressure, and continue cycling without a failed transaction in the recorded run."
    else:
        report["what_it_proves"] = "The testnet vault can absorb multiple deposit and queued-withdraw transactions, close a real live Cetus position under pressure, and continue cycling without failed transaction evidence in the recorded run."
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
