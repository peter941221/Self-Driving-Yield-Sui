#!/usr/bin/env python3
import argparse
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CLOCK_ID = "0x6"
DEFAULT_CETUS_GLOBAL_CONFIG_ID = "0xc6273f844b4bc258952c4e477697aa12c918c8e08106fac6b934811298c9820a"
DEFAULT_CETUS_POOLS_ID = "0x20a086e6fa0741b3ca77d033a65faf0871349b986ddbdde6fa1d85d78a5f4222"
DEFAULT_CETUS_POOL_ID = "0xe8bee419df59bf9b71666255e3956ad8e324b03f39a2c413f174cb157fd84cd8"
DEFAULT_QUOTE_PACKAGE_ID = "0xf6730a6d95217bbcdb8606a543724db089293156268ffa3e9ddca4469ced49d7"
DEFAULT_QUOTE_TREASURY_ID = "0xf47517f6bcd6563007da5e88180c11fae105dcfb6d2739c35288e55f714e8dd2"
DEFAULT_QUOTE_METADATA_ID = "0x646e043cc0f397d75198fe54671c8ad39ef781693e4e8a12c1119d2c08e873b8"
DEFAULT_QUOTE_TYPE = f"{DEFAULT_QUOTE_PACKAGE_ID}::test_quote::TEST_QUOTE"
DEFAULT_PROBE_MANIFEST = ROOT / "out" / "deployments" / "testnet_cetus_live.json"
DEFAULT_VAULT_MANIFEST = ROOT / "out" / "deployments" / "testnet_cetus_vault_live.json"


def sdye_type(package_id):
    return f"{package_id}::sdye::SDYE"


def run(cmd, cwd=ROOT, env=None):
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "unknown error"
        raise SystemExit(f"Command failed: {' '.join(cmd)}\n{message}")
    return result.stdout.strip()


def run_json(cmd, cwd=ROOT, env=None):
    output = run(cmd, cwd=cwd, env=env)
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


def active_env():
    return run(["sui", "client", "active-env"])


def active_address():
    return run(["sui", "client", "active-address"])


def load_balance_groups():
    payload = run_json(["sui", "client", "balance", "--json"])
    return payload[0]


def select_coin_object(coin_type, minimum_balance):
    normalized = coin_type.lower()
    for meta, coins in load_balance_groups():
        if str(meta.get("coinType", "")).lower() != normalized:
            continue
        for coin in coins:
            balance = int(coin.get("balance", "0"))
            if balance >= minimum_balance:
                return coin["coinObjectId"], balance
    raise SystemExit(f"Unable to find owned coin for {coin_type} with balance >= {minimum_balance}")


def mint_quote_coin(amount, treasury_id, recipient):
    payload = run_json([
        "sui", "client", "call",
        "--package", DEFAULT_QUOTE_PACKAGE_ID,
        "--module", "test_quote",
        "--function", "mint",
        "--args", treasury_id, str(amount), recipient,
        "--gas-budget", "50000000",
        "--json",
    ])
    digest = extract_digest(payload)
    tx = tx_block(digest)
    created = next(
        item["objectId"]
        for item in tx.get("objectChanges", [])
        if item.get("type") == "created" and "::test_quote::TEST_QUOTE" in str(item.get("objectType", ""))
    )
    return {"digest": digest, "coin_id": created, "amount": amount}


def ensure_vault_manifest(manifest_path, refresh, force_publish, pool_id):
    manifest_path = Path(manifest_path)
    if manifest_path.exists() and not refresh:
        return json.loads(manifest_path.read_text(encoding="utf-8"))
    cmd = [
        "python", "scripts/deploy_sui.py",
        "--base-type", "0x2::sui::SUI",
        "--min-cycle-interval-ms", "0",
        "--min-snapshot-interval-ms", "0",
        "--cetus-pool-id", pool_id,
        "--gas-budget-publish", "350000000",
        "--gas-budget-call", "120000000",
        "--manifest-out", str(manifest_path),
    ]
    if force_publish:
        cmd.append("--force-publish")
    run(cmd)
    return json.loads(manifest_path.read_text(encoding="utf-8"))


def call_json_with_digest(cmd):
    payload = run_json(cmd)
    return extract_digest(payload), payload


def run_vault_live(manifest, quote_coin_id, sdye_coin_id, amount, tick_lower, tick_upper, clock_id):
    package_id = manifest["package_id"]
    vault_id = manifest["vault_id"]
    config_id = manifest["config_id"]
    current_sdye_type = sdye_type(package_id)
    open_digest, _ = call_json_with_digest([
        "sui", "client", "call",
        "--package", package_id,
        "--module", "cetus_live",
        "--function", "open_position_into_vault_entry",
        "--type-args", "0x2::sui::SUI", DEFAULT_QUOTE_TYPE, current_sdye_type,
        "--args",
        vault_id,
        config_id,
        DEFAULT_CETUS_GLOBAL_CONFIG_ID,
        manifest["config"]["cetus_pool_id"],
        quote_coin_id,
        sdye_coin_id,
        str((tick_lower + (1 << 32)) % (1 << 32)),
        str((tick_upper + (1 << 32)) % (1 << 32)),
        str(amount),
        "true",
        clock_id,
        "--gas-budget", "120000000",
        "--json",
    ])
    open_tx = tx_block(open_digest)
    open_event = next(item for item in open_tx.get("events", []) if str(item.get("type", "")).endswith("::cetus_live::CetusPositionOpenedEvent"))
    position_id = open_event["parsedJson"]["position_id"]

    close_digest, _ = call_json_with_digest([
        "sui", "client", "call",
        "--package", package_id,
        "--module", "cetus_live",
        "--function", "close_stored_position_from_vault_entry",
        "--type-args", "0x2::sui::SUI", DEFAULT_QUOTE_TYPE, current_sdye_type,
        "--args",
        vault_id,
        config_id,
        DEFAULT_CETUS_GLOBAL_CONFIG_ID,
        manifest["config"]["cetus_pool_id"],
        clock_id,
        "--gas-budget", "120000000",
        "--json",
    ])
    close_tx = tx_block(close_digest)
    close_event = next(item for item in close_tx.get("events", []) if str(item.get("type", "")).endswith("::cetus_live::CetusPositionClosedEvent"))
    return {
        "open_digest": open_digest,
        "close_digest": close_digest,
        "position_id": position_id,
        "open_event": open_event.get("parsedJson", {}),
        "close_event": close_event.get("parsedJson", {}),
    }


def main():
    parser = argparse.ArgumentParser(description="One-click Cetus live suite: mint fresh TEST_QUOTE, run real-object probe, then run vault-held Position open/close")
    parser.add_argument("--probe-manifest", default=str(DEFAULT_PROBE_MANIFEST))
    parser.add_argument("--vault-manifest", default=str(DEFAULT_VAULT_MANIFEST))
    parser.add_argument("--refresh-vault-manifest", action="store_true")
    parser.add_argument("--force-publish-vault", action="store_true")
    parser.add_argument("--quote-amount", type=int, default=50_000_000)
    parser.add_argument("--sdye-amount", type=int, default=50_000_000)
    parser.add_argument("--vault-amount", type=int, default=25_000_000)
    parser.add_argument("--tick-lower", type=int, default=-200)
    parser.add_argument("--tick-upper", type=int, default=200)
    parser.add_argument("--clock-id", default=DEFAULT_CLOCK_ID)
    parser.add_argument("--report-out", default="")
    args = parser.parse_args()

    report_path = Path(args.report_out) if args.report_out else ROOT / "out" / "reports" / f"cetus_live_suite_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)

    sender = active_address()
    report = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "env": active_env(),
        "address": sender,
        "status": "started",
        "probe_manifest": str(args.probe_manifest),
        "vault_manifest": str(args.vault_manifest),
        "cetus_global_config_id": DEFAULT_CETUS_GLOBAL_CONFIG_ID,
        "cetus_pool_id": DEFAULT_CETUS_POOL_ID,
        "steps": [],
    }

    minted_probe = mint_quote_coin(args.quote_amount, DEFAULT_QUOTE_TREASURY_ID, sender)
    report["steps"].append({"step": "mint_quote_for_probe", **minted_probe})
    probe_manifest = json.loads(Path(args.probe_manifest).read_text(encoding="utf-8"))
    probe_sdye_type = sdye_type(probe_manifest["package_id"])
    sdye_probe_id, sdye_probe_balance = select_coin_object(probe_sdye_type, args.sdye_amount)

    probe_cmd = [
        "python", "scripts/cetus_live_probe.py",
        "--manifest", str(args.probe_manifest),
        "--coin-type-a", DEFAULT_QUOTE_TYPE,
        "--coin-type-b", probe_sdye_type,
        "--coin-a-id", minted_probe["coin_id"],
        "--coin-b-id", sdye_probe_id,
        "--cetus-global-config-id", DEFAULT_CETUS_GLOBAL_CONFIG_ID,
        "--cetus-pool-id", DEFAULT_CETUS_POOL_ID,
        "--tick-lower", str(args.tick_lower),
        "--tick-upper", str(args.tick_upper),
        "--amount", str(args.quote_amount // 2),
        "--gas-budget-call", "120000000",
    ]
    probe_output = run(probe_cmd)
    report["steps"].append({"step": "cetus_live_probe", "output": probe_output})

    minted_vault = mint_quote_coin(args.vault_amount, DEFAULT_QUOTE_TREASURY_ID, sender)
    report["steps"].append({"step": "mint_quote_for_vault_live", **minted_vault})
    vault_manifest = ensure_vault_manifest(args.vault_manifest, args.refresh_vault_manifest, args.force_publish_vault, DEFAULT_CETUS_POOL_ID)
    vault_sdye_type = sdye_type(vault_manifest["package_id"])
    sdye_vault_id, _ = select_coin_object(vault_sdye_type, args.vault_amount)
    vault_live = run_vault_live(vault_manifest, minted_vault["coin_id"], sdye_vault_id, args.vault_amount, args.tick_lower, args.tick_upper, args.clock_id)
    report["steps"].append({"step": "vault_live", **vault_live})

    report["status"] = "ok"
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
