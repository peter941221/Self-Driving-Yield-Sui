#!/usr/bin/env python3
import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

import cetus_live_suite as suite


ROOT = Path(__file__).resolve().parents[1]
CANONICAL_SUI_TYPE = "0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI"


def find_created_coin_id(tx_block, coin_type):
    normalized = coin_type.lower()
    for item in tx_block.get("objectChanges", []):
        object_type = str(item.get("objectType", "")).lower()
        if item.get("type") != "created":
            continue
        if "::coin::coin<" not in object_type:
            continue
        if normalized in object_type:
            return item["objectId"]
    raise SystemExit(f"Unable to find created coin object for {coin_type}")


def find_event(tx_block, suffix):
    for item in tx_block.get("events", []):
        if str(item.get("type", "")).endswith(suffix):
            return item
    raise SystemExit(f"Unable to find event ending with {suffix}")


def find_event_index(tx_block, suffix):
    for index, item in enumerate(tx_block.get("events", [])):
        if str(item.get("type", "")).endswith(suffix):
            return index
    raise SystemExit(f"Unable to find event ending with {suffix}")


def normalize_tick(value):
    return str((value + (1 << 32)) % (1 << 32))


def deposit_and_get_share_coin(manifest, deposit_amount, clock_id):
    package_id = manifest["package_id"]
    vault_id = manifest["vault_id"]
    base_type = manifest["base_type"]
    share_type = f"{package_id}::sdye::SDYE"
    if base_type == "0x2::sui::SUI":
        gas_payload = suite.run_json(["sui", "client", "gas", "--json"])
        best_gas_coin = max(gas_payload, key=lambda item: int(item.get("mistBalance", 0)))["gasCoinId"]
        digest, _ = suite.call_json_with_digest([
            "sui", "client", "ptb",
            "--gas-coin", f"@{best_gas_coin}",
            "--split-coins", "gas", f"[{deposit_amount}]",
            "--assign", "BASE",
            "--move-call", f"{package_id}::entrypoints::deposit_entry", f"<{base_type}>", f"@{vault_id}", "BASE.0", f"@{clock_id}",
            "--gas-budget", "120000000",
            "--json",
        ])
    else:
        selector_type = CANONICAL_SUI_TYPE if base_type == "0x2::sui::SUI" else base_type
        base_coin_id, _ = suite.select_coin_object(selector_type, deposit_amount)
        digest, _ = suite.call_json_with_digest([
            "sui", "client", "call",
            "--package", package_id,
            "--module", "entrypoints",
            "--function", "deposit_entry",
            "--type-args", base_type,
            "--args", vault_id, base_coin_id, clock_id,
            "--gas-budget", "120000000",
            "--json",
        ])
    tx = suite.tx_block(digest)
    share_coin_id = find_created_coin_id(tx, share_type)
    return {"digest": digest, "share_coin_id": share_coin_id, "share_type": share_type}


def run_plain_cycle(manifest, spot_price, clock_id):
    digest, _ = suite.call_json_with_digest([
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
        suite.DEFAULT_CLOCK_ID,
        "--gas-budget", "120000000",
        "--json",
    ])
    tx = suite.tx_block(digest)
    cycle_event = find_event(tx, "::entrypoints::CycleEvent")
    return {"digest": digest, "cycle_event": cycle_event.get("parsedJson", {})}


def open_live_position(manifest, quote_amount, tick_lower, tick_upper, clock_id):
    quote = suite.mint_quote_coin(quote_amount, suite.DEFAULT_QUOTE_TREASURY_ID, suite.active_address())
    sdye_coin_id, _ = suite.select_coin_object(suite.DEFAULT_SDYE_TYPE, quote_amount)
    digest, _ = suite.call_json_with_digest([
        "sui", "client", "call",
        "--package", manifest["package_id"],
        "--module", "cetus_live",
        "--function", "open_position_into_vault_entry",
        "--type-args", manifest["base_type"], suite.DEFAULT_QUOTE_TYPE, suite.DEFAULT_SDYE_TYPE,
        "--args",
        manifest["vault_id"],
        manifest["config_id"],
        suite.DEFAULT_CETUS_GLOBAL_CONFIG_ID,
        manifest["config"]["cetus_pool_id"],
        quote["coin_id"],
        sdye_coin_id,
        normalize_tick(tick_lower),
        normalize_tick(tick_upper),
        str(quote_amount),
        "true",
        clock_id,
        "--gas-budget", "120000000",
        "--json",
    ])
    tx = suite.tx_block(digest)
    opened = find_event(tx, "::cetus_live::CetusPositionOpenedEvent")
    return {
        "mint": quote,
        "digest": digest,
        "open_event": opened.get("parsedJson", {}),
        "legacy_sdye_coin_id": sdye_coin_id,
    }


def request_queued_withdraw(manifest, share_coin_id, clock_id):
    digest, _ = suite.call_json_with_digest([
        "sui", "client", "call",
        "--package", manifest["package_id"],
        "--module", "entrypoints",
        "--function", "request_withdraw_entry",
        "--type-args", manifest["base_type"],
        "--args",
        manifest["vault_id"],
        manifest["queue_id"],
        share_coin_id,
        clock_id,
        "--gas-budget", "120000000",
        "--json",
    ])
    tx = suite.tx_block(digest)
    event = find_event(tx, "::entrypoints::WithdrawRequestedEvent")
    parsed = event.get("parsedJson", {})
    if not parsed.get("queued", False):
        raise SystemExit("Expected queued withdrawal before cycle_live probe, but withdraw was instant")
    return {"digest": digest, "withdraw_event": parsed}


def run_cycle_live(manifest, spot_price, clock_id):
    digest, _ = suite.call_json_with_digest([
        "sui", "client", "call",
        "--package", manifest["package_id"],
        "--module", "cetus_live",
        "--function", "cycle_live_entry",
        "--type-args", manifest["base_type"], suite.DEFAULT_QUOTE_TYPE, suite.DEFAULT_SDYE_TYPE,
        "--args",
        manifest["vault_id"],
        manifest["queue_id"],
        manifest["config_id"],
        suite.DEFAULT_CETUS_GLOBAL_CONFIG_ID,
        manifest["config"]["cetus_pool_id"],
        str(spot_price),
        clock_id,
        "--gas-budget", "120000000",
        "--json",
    ])
    tx = suite.tx_block(digest)
    close_event = find_event(tx, "::cetus_live::CetusPositionClosedEvent")
    cycle_event = find_event(tx, "::entrypoints::CycleEvent")
    close_index = find_event_index(tx, "::cetus_live::CetusPositionClosedEvent")
    cycle_index = find_event_index(tx, "::entrypoints::CycleEvent")
    if not close_index < cycle_index:
        raise SystemExit(
            f"Expected close event to happen before CycleEvent in cycle_live tx, got close_index={close_index}, cycle_index={cycle_index}"
        )
    return {
        "digest": digest,
        "close_event": close_event.get("parsedJson", {}),
        "cycle_event": cycle_event.get("parsedJson", {}),
        "close_event_index": close_index,
        "cycle_event_index": cycle_index,
    }


def main():
    parser = argparse.ArgumentParser(description="Publish-or-reuse a vault manifest, create queue pressure, then prove cycle_live closes before CycleEvent on testnet")
    parser.add_argument("--manifest", default=str(ROOT / "out" / "deployments" / "testnet_cetus_cycle_live.json"))
    parser.add_argument("--refresh-manifest", action="store_true")
    parser.add_argument("--force-publish", action="store_true")
    parser.add_argument("--deposit-amount", type=int, default=1_000_000_000)
    parser.add_argument("--open-amount", type=int, default=25_000_000)
    parser.add_argument("--spot-price", type=int, default=1_000_000_000)
    parser.add_argument("--tick-lower", type=int, default=-200)
    parser.add_argument("--tick-upper", type=int, default=200)
    parser.add_argument("--clock-id", default=suite.DEFAULT_CLOCK_ID)
    parser.add_argument("--report-out", default="")
    args = parser.parse_args()

    report_path = Path(args.report_out) if args.report_out else ROOT / "out" / "reports" / f"cetus_cycle_live_probe_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)

    manifest = suite.ensure_vault_manifest(args.manifest, args.refresh_manifest, args.force_publish, suite.DEFAULT_CETUS_POOL_ID)
    report = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "env": suite.active_env(),
        "address": suite.active_address(),
        "manifest": str(args.manifest),
        "package_id": manifest["package_id"],
        "vault_id": manifest["vault_id"],
        "queue_id": manifest["queue_id"],
        "config_id": manifest["config_id"],
        "cetus_pool_id": manifest["config"]["cetus_pool_id"],
        "status": "started",
        "steps": [],
    }

    deposit = deposit_and_get_share_coin(manifest, args.deposit_amount, args.clock_id)
    report["steps"].append({"step": "deposit_entry", **deposit})

    first_cycle = run_plain_cycle(manifest, args.spot_price, args.clock_id)
    report["steps"].append({"step": "cycle_entry_before_live_position", **first_cycle})

    live_open = open_live_position(manifest, args.open_amount, args.tick_lower, args.tick_upper, args.clock_id)
    report["steps"].append({"step": "open_position_into_vault_entry", **live_open})

    withdraw = request_queued_withdraw(manifest, deposit["share_coin_id"], args.clock_id)
    report["steps"].append({"step": "request_withdraw_entry", **withdraw})

    cycle_live = run_cycle_live(manifest, args.spot_price, args.clock_id)
    report["steps"].append({"step": "cycle_live_entry", **cycle_live})

    report["status"] = "ok"
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
