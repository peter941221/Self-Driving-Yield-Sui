#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import subprocess
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME_DIR = ROOT / "cache" / "scallop_sdk_runtime"
PACKAGE_JSON = RUNTIME_DIR / "package.json"
RUNNER_FILE = RUNTIME_DIR / "run_probe.mjs"
ARGS_FILE = RUNTIME_DIR / "probe_args.json"

SCALLOP_ADDRESS_ID = "67c44a103fe1b8c454eb9699"
MAINNET_RPC_URL = "https://fullnode.mainnet.sui.io:443"
MIN_GAS_BUDGET_MIST = 50_000_000

PACKAGE_JSON_CONTENT = {
    "name": "scallop-probe-runtime",
    "private": True,
    "type": "module",
    "dependencies": {
        "@scallop-io/sui-scallop-sdk": "2.2.0"
    },
}

RUNNER_SOURCE = r'''
import fs from 'node:fs';
import { Scallop } from '@scallop-io/sui-scallop-sdk';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const args = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const sdk = new Scallop({
  addressId: args.addressId,
  networkType: 'mainnet',
  fullnodeUrls: [args.rpcUrl],
  secretKey: args.secretKey,
});
const builder = await sdk.createScallopBuilder();
const sender = builder.walletAddress;

async function safeQuery(label, fn) {
  try {
    return await fn();
  } catch (error) {
    return { error: `${label}: ${String(error)}` };
  }
}

async function snapshot(poolCoinName) {
  return {
    lending: await safeQuery('getLending', () => builder.query.getLending(poolCoinName, sender, { indexer: false })),
    market_coin_amount: await safeQuery('getMarketCoinAmount', () => builder.query.getMarketCoinAmount(poolCoinName, sender)),
    user_portfolio: await safeQuery('getUserPortfolio', () => builder.query.getUserPortfolio({ walletAddress: sender, indexer: false })),
    obligations: await safeQuery('getObligations', () => builder.query.getObligations(sender)),
  };
}

const before = await snapshot(args.poolCoinName);
if (args.queryOnly) {
  process.stdout.write(JSON.stringify({
    status: 'query_only',
    sender,
    before,
  }, null, 2));
  process.exit(0);
}

const depositTx = builder.createTxBlock();
depositTx.setSender(sender);
const receiptCoin = await depositTx.depositQuick(args.amount, args.poolCoinName);
depositTx.transferObjects([receiptCoin], sender);
const depositResult = await builder.signAndSendTxBlock(depositTx);
await sleep(args.waitMs);

const afterDeposit = await snapshot(args.poolCoinName);

const lendingAfterDeposit = afterDeposit?.lending ?? {};
const withdrawAmount = Math.floor(
  lendingAfterDeposit.unstakedMarketAmount ??
  lendingAfterDeposit.availableStakeAmount ??
  args.amount
);
if (!withdrawAmount || withdrawAmount <= 0) {
  throw new Error(`No withdrawable Scallop market/sCoin amount found after deposit for ${args.poolCoinName}`);
}

const withdrawTx = builder.createTxBlock();
withdrawTx.setSender(sender);
const withdrawnCoin = await withdrawTx.withdrawQuick(withdrawAmount, args.poolCoinName);
withdrawTx.transferObjects([withdrawnCoin], sender);
const withdrawResult = await builder.signAndSendTxBlock(withdrawTx);
await sleep(args.waitMs);

const afterWithdraw = await snapshot(args.poolCoinName);

process.stdout.write(JSON.stringify({
  status: 'ok',
  sender,
  before,
  deposit: {
    digest: depositResult.digest,
    effects: depositResult.effects ?? null,
  },
  after_deposit: afterDeposit,
  withdraw: {
    requested_amount: withdrawAmount,
    digest: withdrawResult.digest,
    effects: withdrawResult.effects ?? null,
  },
  after_withdraw: afterWithdraw,
}, null, 2));
'''


def resolve_pnpm():
    return shutil.which("pnpm") or shutil.which("pnpm.cmd") or str(Path.home() / "AppData" / "Roaming" / "npm" / "pnpm.cmd")


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


def rpc_call(method, params, rpc_url=MAINNET_RPC_URL):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = urllib.request.Request(rpc_url, data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        body = json.load(response)
    if "error" in body:
        raise SystemExit(f"RPC error: {body['error']}")
    return body["result"]


def active_address():
    return run(["sui", "client", "active-address"])


def ensure_secret_key():
    env_key = os.environ.get("SUI_SECRET_KEY", "").strip()
    if env_key:
        return env_key, "env"
    keys = run_json(["sui", "keytool", "list", "--json"])
    active = active_address().lower()
    match = next((item for item in keys if str(item.get("suiAddress", "")).lower() == active), None)
    if not match:
        raise SystemExit(f"Unable to match active address {active} in `sui keytool list --json`")
    exported = run_json(["sui", "keytool", "export", "--key-identity", match["alias"], "--json"])
    return exported["exportedPrivateKey"], f"keytool:{match['alias']}"


def ensure_runtime(skip_install=False):
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    package_json_text = json.dumps(PACKAGE_JSON_CONTENT, indent=2) + "\n"
    package_changed = not PACKAGE_JSON.exists() or PACKAGE_JSON.read_text(encoding="utf-8") != package_json_text
    runner_changed = not RUNNER_FILE.exists() or RUNNER_FILE.read_text(encoding="utf-8") != RUNNER_SOURCE
    if package_changed:
        PACKAGE_JSON.write_text(package_json_text, encoding="utf-8")
    if runner_changed:
        RUNNER_FILE.write_text(RUNNER_SOURCE, encoding="utf-8")

    node_modules = RUNTIME_DIR / "node_modules"
    if skip_install and node_modules.exists() and not package_changed:
        return
    if package_changed and node_modules.exists():
        shutil.rmtree(node_modules)
    if not node_modules.exists():
        run([resolve_pnpm(), "install"], cwd=RUNTIME_DIR)


def extract_relevant_object_ids(tx_result):
    relevant = {
        "created": [],
        "mutated": [],
        "coins": [],
        "obligations": [],
    }
    for change in tx_result.get("objectChanges", []) or []:
        entry = {
            "type": change.get("type"),
            "objectId": change.get("objectId"),
            "objectType": change.get("objectType"),
        }
        if change.get("type") == "created":
            relevant["created"].append(entry)
        elif change.get("type") in {"mutated", "transferred", "published"}:
            relevant["mutated"].append(entry)
        object_type = str(change.get("objectType", ""))
        if "::coin::Coin<" in object_type:
            relevant["coins"].append(entry)
        if object_type.endswith("::obligation::Obligation") or "::obligation::Obligation" in object_type:
            relevant["obligations"].append(entry)
    return relevant


def fetch_tx(digest, rpc_url=MAINNET_RPC_URL):
    return rpc_call(
        "sui_getTransactionBlock",
        [
            digest,
            {
                "showEffects": True,
                "showEvents": True,
                "showObjectChanges": True,
                "showBalanceChanges": True,
                "showInput": True,
            },
        ],
        rpc_url,
    )


def main():
    parser = argparse.ArgumentParser(description="Run a real Scallop supply -> query -> withdraw probe on mainnet using the official Scallop SDK, or archive a blocked report when preflight fails")
    parser.add_argument("--pool-coin-name", default="sui", help="Scallop pool coin name, e.g. `sui` or `wusdc`")
    parser.add_argument("--amount", type=int, default=10_000_000, help="Supply amount in base units; default = 0.01 SUI when pool coin is `sui`")
    parser.add_argument("--rpc-url", default=MAINNET_RPC_URL)
    parser.add_argument("--wait-ms", type=int, default=3000)
    parser.add_argument("--skip-install", action="store_true")
    parser.add_argument("--report-out", default="")
    args = parser.parse_args()

    report_path = Path(args.report_out) if args.report_out else ROOT / "out" / "reports" / f"scallop_supply_probe_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)

    address = active_address()
    secret_key, secret_source = ensure_secret_key()
    mainnet_sui_balance = int(rpc_call("suix_getBalance", [address, "0x2::sui::SUI"], args.rpc_url).get("totalBalance", "0"))
    required_balance = MIN_GAS_BUDGET_MIST + (args.amount if args.pool_coin_name == "sui" else 0)
    query_only = mainnet_sui_balance < required_balance

    base_report = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "protocol": "scallop",
        "env": "mainnet",
        "address": address,
        "sdk_address_id": SCALLOP_ADDRESS_ID,
        "sdk_boundary": {
            "network_support": "mainnet_only",
            "note": "Official Scallop SDK README states testnet is unsupported because no testnet package addresses are provided.",
        },
        "requested": {
            "pool_coin_name": args.pool_coin_name,
            "amount": args.amount,
            "rpc_url": args.rpc_url,
        },
        "preflight": {
            "secret_source": secret_source,
            "mainnet_sui_balance_mist": mainnet_sui_balance,
            "required_mainnet_sui_balance_mist": required_balance,
            "query_only": query_only,
        },
    }

    try:
        ensure_runtime(skip_install=args.skip_install)
        ARGS_FILE.write_text(json.dumps({
            "addressId": SCALLOP_ADDRESS_ID,
            "rpcUrl": args.rpc_url,
            "secretKey": secret_key,
            "poolCoinName": args.pool_coin_name,
            "amount": args.amount,
            "waitMs": args.wait_ms,
            "queryOnly": query_only,
        }, indent=2), encoding="utf-8")

        result = subprocess.run(
            ["node", str(RUNNER_FILE), str(ARGS_FILE)],
            cwd=RUNTIME_DIR,
            capture_output=True,
            text=True,
            env=os.environ.copy(),
        )
        stdout = result.stdout.strip()
        stderr = result.stderr.strip()
        if result.returncode != 0:
            report = {
                **base_report,
                "status": "failed",
                "returncode": result.returncode,
                "stdout": stdout,
                "stderr": stderr,
            }
            report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
            raise SystemExit(stderr or stdout or f"Scallop probe failed. Report written to {report_path}")

        runner_payload = json.loads(stdout)
        if query_only:
            report = {
                **base_report,
                "status": "blocked_no_mainnet_gas",
                "query_snapshot": runner_payload,
                "what_it_proves": "Official Scallop SDK wiring works on mainnet query path for the active wallet, but live supply/withdraw is blocked by insufficient mainnet SUI for gas and/or supply.",
                "what_it_does_not_prove": "No real deposit or withdraw transaction was sent in this run.",
            }
            report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
            raise SystemExit(f"Blocked: insufficient mainnet SUI for a real Scallop probe. Report written to {report_path}")

        deposit_tx = fetch_tx(runner_payload["deposit"]["digest"], args.rpc_url)
        withdraw_tx = fetch_tx(runner_payload["withdraw"]["digest"], args.rpc_url)
        report = {
            **base_report,
            "status": "ok",
            "query_snapshot_before": runner_payload.get("before"),
            "query_snapshot_after_deposit": runner_payload.get("after_deposit"),
            "query_snapshot_after_withdraw": runner_payload.get("after_withdraw"),
            "steps": [
                {
                    "step": "depositQuick",
                    "digest": runner_payload["deposit"]["digest"],
                    "tx": deposit_tx,
                    "relevant_object_ids": extract_relevant_object_ids(deposit_tx),
                },
                {
                    "step": "withdrawQuick",
                    "digest": runner_payload["withdraw"]["digest"],
                    "tx": withdraw_tx,
                    "relevant_object_ids": extract_relevant_object_ids(withdraw_tx),
                },
            ],
            "what_it_proves": "A real Scallop supply -> query -> withdraw flow completed on mainnet using the official Scallop SDK.",
            "what_it_does_not_prove": "This run does not yet wire Scallop directly into `yield_source.move` or vault cycle accounting.",
        }
        report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(json.dumps(report, indent=2))
    except SystemExit:
        raise
    except Exception as exc:
        report = {
            **base_report,
            "status": "failed_exception",
            "error": str(exc),
        }
        report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
        raise SystemExit(f"Scallop supply probe failed: {exc}. Report written to {report_path}") from exc


if __name__ == "__main__":
    main()
