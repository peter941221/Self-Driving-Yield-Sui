#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import socketserver
import subprocess
import sys
import tempfile
import textwrap
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def write_json(path: Path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def make_fake_sui_bin(bin_dir: Path, active_env: str = "testnet", active_address: str = "0xchaos", gas_payload=None):
    bin_dir.mkdir(parents=True, exist_ok=True)
    if gas_payload is None:
        gas_payload = {"data": []}
    driver = bin_dir / "sui.py"
    driver.write_text(
        textwrap.dedent(
            f"""
            import json
            import sys

            active_env = {active_env!r}
            active_address = {active_address!r}
            gas_payload = {json.dumps(gas_payload)}

            args = sys.argv[1:]
            if args == ["client", "active-env"]:
                print(active_env)
                raise SystemExit(0)
            if args == ["client", "active-address"]:
                print(active_address)
                raise SystemExit(0)
            if args == ["client", "gas", "--json"]:
                print(json.dumps(gas_payload))
                raise SystemExit(0)
            if args == ["client", "envs"]:
                print("alias │ url │ active")
                print("testnet │ http://127.0.0.1:9999 │ *")
                raise SystemExit(0)
            print("unexpected fake sui invocation:", " ".join(args), file=sys.stderr)
            raise SystemExit(91)
            """
        ).strip()
        + "\n",
        encoding="utf-8",
    )
    for shim_name in ("sui.bat", "sui.cmd"):
        shim = bin_dir / shim_name
        shim.write_text("@echo off\r\npython \"%~dp0sui.py\" %*\r\n", encoding="utf-8")


class RpcHandler(BaseHTTPRequestHandler):
    responses = []

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        payload = json.loads(body)
        if RpcHandler.responses:
            response = RpcHandler.responses.pop(0)
        else:
            response = {"jsonrpc": "2.0", "id": payload.get("id", 1), "result": {"data": []}}
        encoded = json.dumps(response).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *_args):
        return


def start_rpc_server(responses):
    RpcHandler.responses = list(responses)
    server = socketserver.TCPServer(("127.0.0.1", 0), RpcHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


def run_cmd(cmd, env=None):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, env=env)


def base_manifest(network="testnet"):
    return {
        "network": network,
        "base_type": "0x2::sui::SUI",
        "package_id": "0xpackage",
        "vault_id": "0xvault",
        "queue_id": "0xqueue",
        "config_id": "0xconfig",
        "admin_cap_id": "0xadmin",
    }


def ok_scallop_report(env="testnet", before=0, after_deposit=100, after_withdraw=0):
    return {
        "status": "ok",
        "env": env,
        "query_snapshot_before": {"lending": {"availableWithdrawAmount": before}},
        "query_snapshot_after_deposit": {"lending": {"availableWithdrawAmount": after_deposit}},
        "query_snapshot_after_withdraw": {"lending": {"availableWithdrawAmount": after_withdraw}},
        "steps": [
            {
                "digest": "FAKE_DIGEST",
                "relevant_object_ids": {
                    "created": [
                        {"objectType": "0x2::scallop_sui::SCALLOP_SUI", "objectId": "0xreceipt"}
                    ]
                },
            }
        ],
    }


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def experiment_bridge(name, tmp_dir: Path, report_payload, fake_env="testnet", expect_status=""):
    fake_bin = tmp_dir / name / "fakebin"
    make_fake_sui_bin(fake_bin, active_env=fake_env)
    env = os.environ.copy()
    env["PATH"] = str(fake_bin) + os.pathsep + env.get("PATH", "")
    env["PATHEXT"] = ".BAT;.CMD;.EXE;.COM"
    env["SUI_BIN"] = str(fake_bin / "sui.bat")
    manifest_path = tmp_dir / name / "manifest.json"
    report_path = tmp_dir / name / "report.json"
    out_path = tmp_dir / name / "bridge_report.json"
    write_json(manifest_path, base_manifest("testnet"))
    write_json(report_path, report_payload)
    result = run_cmd([
        sys.executable,
        "scripts/scallop_core_bridge.py",
        "--manifest",
        str(manifest_path),
        "--report",
        str(report_path),
        "--report-out",
        str(out_path),
    ], env=env)
    actual = load_json(out_path).get("status") if out_path.exists() else "missing_report"
    return {
        "name": name,
        "command": "scallop_core_bridge.py",
        "expected_status": expect_status,
        "actual_status": actual,
        "pass": actual == expect_status,
        "returncode": result.returncode,
        "stdout": result.stdout[-4000:],
        "stderr": result.stderr[-4000:],
        "artifact": str(out_path),
    }


def experiment_smoke_blocked(tmp_dir: Path):
    name = "smoke_blocked_no_testnet_gas"
    fake_bin = tmp_dir / name / "fakebin"
    make_fake_sui_bin(fake_bin, active_env="testnet", active_address="0xsmoke", gas_payload={"data": []})
    env = os.environ.copy()
    env["PATH"] = str(fake_bin) + os.pathsep + env.get("PATH", "")
    env["PATHEXT"] = ".BAT;.CMD;.EXE;.COM"
    env["SUI_BIN"] = str(fake_bin / "sui.bat")
    out_path = tmp_dir / name / "smoke_report.json"
    result = run_cmd([
        sys.executable,
        "scripts/testnet_cycle_smoke.py",
        "--manifest",
        str(tmp_dir / name / "unused_manifest.json"),
        "--report-out",
        str(out_path),
        "--cycles",
        "1",
    ], env=env)
    actual = load_json(out_path).get("status") if out_path.exists() else "missing_report"
    return {
        "name": name,
        "command": "testnet_cycle_smoke.py",
        "expected_status": "blocked_no_testnet_gas",
        "actual_status": actual,
        "pass": actual == "blocked_no_testnet_gas",
        "returncode": result.returncode,
        "stdout": result.stdout[-4000:],
        "stderr": result.stderr[-4000:],
        "artifact": str(out_path),
    }


def experiment_monitor_no_events(tmp_dir: Path):
    name = "monitor_no_events"
    server, rpc_url = start_rpc_server([
        {"jsonrpc": "2.0", "id": 1, "result": {"data": []}},
        {"jsonrpc": "2.0", "id": 1, "result": {"data": []}},
    ])
    try:
        manifest_path = tmp_dir / name / "manifest.json"
        write_json(manifest_path, base_manifest("testnet"))
        result = run_cmd([
            sys.executable,
            "scripts/monitor_sui.py",
            "--manifest",
            str(manifest_path),
            "--rpc-url",
            rpc_url,
            "--limit",
            "5",
        ])
        combined = (result.stdout or "") + "\n" + (result.stderr or "")
        passed = result.returncode != 0 and "ALERT: no events found" in combined and "OK: no alert thresholds triggered" not in combined
        return {
            "name": name,
            "command": "monitor_sui.py",
            "expected_status": "no_events_alert",
            "actual_status": "pass" if passed else "fail",
            "pass": passed,
            "returncode": result.returncode,
            "stdout": result.stdout[-4000:],
            "stderr": result.stderr[-4000:],
            "artifact": str(manifest_path),
        }
    finally:
        server.shutdown()
        server.server_close()


def experiment_monitor_pressure(tmp_dir: Path):
    name = "monitor_only_unwind_pressure"
    cycle_event = {
        "type": "0xpackage::entrypoints::CycleEvent",
        "timestampMs": str(int(datetime.now(timezone.utc).timestamp() * 1000)),
        "parsedJson": {
            "spot_price": 100000,
            "moved_usdc": 0,
            "bounty_usdc": 0,
            "regime_code": 2,
            "only_unwind": True,
            "safe_cycles_since_storm": 0,
            "treasury_usdc": 100,
            "deployed_usdc": 900,
            "ready_usdc": 250,
            "pending_usdc": 300,
            "used_flash": False,
            "total_assets": 1000,
        },
    }
    server, rpc_url = start_rpc_server([
        {"jsonrpc": "2.0", "id": 1, "result": {"data": [cycle_event]}},
        {"jsonrpc": "2.0", "id": 1, "result": {"data": []}},
    ])
    try:
        manifest_path = tmp_dir / name / "manifest.json"
        write_json(manifest_path, base_manifest("testnet"))
        result = run_cmd([
            sys.executable,
            "scripts/monitor_sui.py",
            "--manifest",
            str(manifest_path),
            "--rpc-url",
            rpc_url,
            "--limit",
            "5",
        ])
        combined = (result.stdout or "") + "\n" + (result.stderr or "")
        passed = (
            result.returncode == 0
            and "HIGH: vault is in OnlyUnwind mode" in combined
            and ("CRIT: ready withdrawals exceed treasury liquidity" in combined or "WARN: treasury sits below derived reserve target" in combined)
            and "OK: no alert thresholds triggered" not in combined
        )
        return {
            "name": name,
            "command": "monitor_sui.py",
            "expected_status": "alerted_pressure",
            "actual_status": "pass" if passed else "fail",
            "pass": passed,
            "returncode": result.returncode,
            "stdout": result.stdout[-4000:],
            "stderr": result.stderr[-4000:],
            "artifact": str(manifest_path),
        }
    finally:
        server.shutdown()
        server.server_close()


def main():
    parser = argparse.ArgumentParser(description="Run local chaos Phase 1 experiments against blocker/reporting/operator safety paths")
    parser.add_argument("--report-out", default="")
    args = parser.parse_args()

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    report_path = Path(args.report_out) if args.report_out else ROOT / "out" / "reports" / f"chaos_phase1_{timestamp}.json"
    tmp_dir = ROOT / "out" / "chaos" / f"phase1_{timestamp}"
    if tmp_dir.exists():
        shutil.rmtree(tmp_dir)
    tmp_dir.mkdir(parents=True, exist_ok=True)

    results = []
    results.append(experiment_bridge("bridge_blocked_bad_report_status", tmp_dir, {**ok_scallop_report(), "status": "failed"}, expect_status="blocked_bad_report_status"))
    results.append(experiment_bridge("bridge_blocked_cross_network", tmp_dir, ok_scallop_report(env="mainnet"), expect_status="blocked_cross_network"))
    results.append(experiment_bridge("bridge_blocked_wrong_active_env", tmp_dir, ok_scallop_report(env="testnet"), fake_env="mainnet", expect_status="blocked_wrong_active_env"))
    results.append(experiment_bridge("bridge_blocked_non_isolated_wallet_state", tmp_dir, ok_scallop_report(env="testnet", before=25, after_deposit=125, after_withdraw=0), expect_status="blocked_non_isolated_wallet_state"))
    results.append(experiment_smoke_blocked(tmp_dir))
    results.append(experiment_monitor_no_events(tmp_dir))
    results.append(experiment_monitor_pressure(tmp_dir))

    passed = sum(1 for item in results if item["pass"])
    summary = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "status": "ok" if passed == len(results) else "failed",
        "passed": passed,
        "total": len(results),
        "results": results,
    }
    write_json(report_path, summary)
    print(json.dumps(summary, indent=2))
    if summary["status"] != "ok":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
