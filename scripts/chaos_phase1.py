#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import socketserver
import subprocess
import sys
import textwrap
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def write_json(path: Path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def tail(text: str, limit: int = 4000):
    return (text or "")[-limit:]


def fake_sui_executable(bin_dir: Path) -> str:
    return str((bin_dir / "sui").resolve()) if os.name != "nt" else str((bin_dir / "sui.bat").resolve())


def make_fake_sui_bin(
    bin_dir: Path,
    *,
    active_env: str = "testnet",
    active_address: str = "0xchaos",
    gas_payload=None,
    call_payloads=None,
):
    bin_dir.mkdir(parents=True, exist_ok=True)
    if gas_payload is None:
        gas_payload = {"data": []}
    if call_payloads is None:
        call_payloads = []

    driver = bin_dir / "sui.py"
    driver.write_text(
        textwrap.dedent(
            f"""
            import json
            import sys

            active_env = {active_env!r}
            active_address = {active_address!r}
            gas_payload = {json.dumps(gas_payload)}
            call_payloads = {json.dumps(call_payloads)}

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
                print(f"{{active_env}} │ http://127.0.0.1:9999 │ *")
                raise SystemExit(0)
            if len(args) >= 2 and args[0] == "client" and args[1] == "call":
                if call_payloads:
                    print(json.dumps(call_payloads.pop(0)))
                    raise SystemExit(0)
                print(json.dumps({{"digest": "FAKE_CALL_DIGEST"}}))
                raise SystemExit(0)
            print("unexpected fake sui invocation:", " ".join(args), file=sys.stderr)
            raise SystemExit(91)
            """
        ).strip()
        + "\n",
        encoding="utf-8",
    )

    unix_shim = bin_dir / "sui"
    unix_shim.write_text('#!/usr/bin/env bash\npython3 "$(dirname "$0")/sui.py" "$@"\n', encoding="utf-8")
    os.chmod(unix_shim, 0o755)

    for shim_name in ("sui.bat", "sui.cmd"):
        shim = bin_dir / shim_name
        shim.write_text("@echo off\r\npython \"%~dp0sui.py\" %*\r\n", encoding="utf-8")


class RpcHandler(BaseHTTPRequestHandler):
    responses = []
    raw_bodies = []

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        _ = self.rfile.read(length)
        if RpcHandler.raw_bodies:
            raw = RpcHandler.raw_bodies.pop(0).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return

        if RpcHandler.responses:
            response = RpcHandler.responses.pop(0)
        else:
            response = {"jsonrpc": "2.0", "id": 1, "result": {"data": []}}
        encoded = json.dumps(response).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *_args):
        return


def start_rpc_server(responses=None, raw_bodies=None):
    RpcHandler.responses = list(responses or [])
    RpcHandler.raw_bodies = list(raw_bodies or [])
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


def run_bridge_experiment(name, tmp_dir: Path, report_payload, *, fake_env="testnet", call_payloads=None, expect_status=""):
    fake_bin = tmp_dir / name / "fakebin"
    make_fake_sui_bin(fake_bin, active_env=fake_env, call_payloads=call_payloads)
    env = os.environ.copy()
    env["PATH"] = str(fake_bin) + os.pathsep + env.get("PATH", "")
    env["PATHEXT"] = ".BAT;.CMD;.EXE;.COM"
    env["SUI_BIN"] = fake_sui_executable(fake_bin)
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
        "stdout": tail(result.stdout),
        "stderr": tail(result.stderr),
        "artifact": str(out_path),
    }


def experiment_bridge_ok(tmp_dir: Path):
    payload = {"digest": "FAKE_SYNC_DIGEST"}
    return run_bridge_experiment(
        "bridge_ok_happy_path",
        tmp_dir,
        ok_scallop_report(env="testnet", before=0, after_deposit=100, after_withdraw=20),
        call_payloads=[payload, payload, payload],
        expect_status="ok",
    )


def experiment_smoke_blocked(tmp_dir: Path):
    name = "smoke_blocked_no_testnet_gas"
    fake_bin = tmp_dir / name / "fakebin"
    make_fake_sui_bin(fake_bin, active_env="testnet", active_address="0xsmoke", gas_payload={"data": []})
    env = os.environ.copy()
    env["PATH"] = str(fake_bin) + os.pathsep + env.get("PATH", "")
    env["PATHEXT"] = ".BAT;.CMD;.EXE;.COM"
    env["SUI_BIN"] = fake_sui_executable(fake_bin)
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
        "stdout": tail(result.stdout),
        "stderr": tail(result.stderr),
        "artifact": str(out_path),
    }


def run_monitor_experiment(name, tmp_dir: Path, *, responses=None, raw_bodies=None, max_minutes_without_cycle="30", expect_status="", validator=None):
    server, rpc_url = start_rpc_server(responses=responses, raw_bodies=raw_bodies)
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
            "--max-minutes-without-cycle",
            str(max_minutes_without_cycle),
        ])
        combined = (result.stdout or "") + "\n" + (result.stderr or "")
        passed = validator(result, combined) if validator else False
        return {
            "name": name,
            "command": "monitor_sui.py",
            "expected_status": expect_status,
            "actual_status": "pass" if passed else "fail",
            "pass": passed,
            "returncode": result.returncode,
            "stdout": tail(result.stdout),
            "stderr": tail(result.stderr),
            "artifact": str(manifest_path),
        }
    finally:
        server.shutdown()
        server.server_close()


def experiment_monitor_no_events(tmp_dir: Path):
    return run_monitor_experiment(
        "monitor_no_events",
        tmp_dir,
        responses=[
            {"jsonrpc": "2.0", "id": 1, "result": {"data": []}},
            {"jsonrpc": "2.0", "id": 1, "result": {"data": []}},
        ],
        expect_status="no_events_alert",
        validator=lambda result, combined: result.returncode != 0 and "ALERT: no events found" in combined and "OK: no alert thresholds triggered" not in combined,
    )


def experiment_monitor_rpc_error(tmp_dir: Path):
    return run_monitor_experiment(
        "monitor_rpc_error",
        tmp_dir,
        responses=[{"jsonrpc": "2.0", "id": 1, "error": {"code": -32000, "message": "chaos rpc error"}}],
        expect_status="rpc_error",
        validator=lambda result, combined: result.returncode != 0 and "RPC error:" in combined and "OK: no alert thresholds triggered" not in combined,
    )


def experiment_monitor_malformed_json(tmp_dir: Path):
    return run_monitor_experiment(
        "monitor_malformed_json",
        tmp_dir,
        raw_bodies=["not-json"],
        expect_status="malformed_json",
        validator=lambda result, combined: result.returncode != 0 and "JSONDecodeError" in combined and "OK: no alert thresholds triggered" not in combined,
    )


def experiment_monitor_pressure(tmp_dir: Path):
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
    return run_monitor_experiment(
        "monitor_only_unwind_pressure",
        tmp_dir,
        responses=[
            {"jsonrpc": "2.0", "id": 1, "result": {"data": [cycle_event]}},
            {"jsonrpc": "2.0", "id": 1, "result": {"data": []}},
        ],
        expect_status="alerted_pressure",
        validator=lambda result, combined: result.returncode == 0 and "HIGH: vault is in OnlyUnwind mode" in combined and "CRIT: ready withdrawals exceed treasury liquidity" in combined and "OK: no alert thresholds triggered" not in combined,
    )


def experiment_monitor_stale_cycle(tmp_dir: Path):
    old_ts_ms = int((datetime.now(timezone.utc).timestamp() - 7200) * 1000)
    cycle_event = {
        "type": "0xpackage::entrypoints::CycleEvent",
        "timestampMs": str(old_ts_ms),
        "parsedJson": {
            "spot_price": 100000,
            "moved_usdc": 0,
            "bounty_usdc": 0,
            "regime_code": 1,
            "only_unwind": False,
            "safe_cycles_since_storm": 2,
            "treasury_usdc": 500,
            "deployed_usdc": 500,
            "ready_usdc": 0,
            "pending_usdc": 0,
            "used_flash": False,
            "total_assets": 1000,
        },
    }
    return run_monitor_experiment(
        "monitor_stale_cycle",
        tmp_dir,
        responses=[
            {"jsonrpc": "2.0", "id": 1, "result": {"data": [cycle_event]}},
            {"jsonrpc": "2.0", "id": 1, "result": {"data": []}},
        ],
        max_minutes_without_cycle="30",
        expect_status="stale_cycle_alert",
        validator=lambda result, combined: result.returncode == 0 and "HIGH: no cycle for" in combined and "OK: no alert thresholds triggered" not in combined,
    )


def experiment_monitor_used_flash(tmp_dir: Path):
    cycle_event = {
        "type": "0xpackage::entrypoints::CycleEvent",
        "timestampMs": str(int(datetime.now(timezone.utc).timestamp() * 1000)),
        "parsedJson": {
            "spot_price": 100000,
            "moved_usdc": 0,
            "bounty_usdc": 0,
            "regime_code": 1,
            "only_unwind": False,
            "safe_cycles_since_storm": 2,
            "treasury_usdc": 700,
            "deployed_usdc": 300,
            "ready_usdc": 0,
            "pending_usdc": 0,
            "used_flash": True,
            "total_assets": 1000,
        },
    }
    return run_monitor_experiment(
        "monitor_used_flash_info",
        tmp_dir,
        responses=[
            {"jsonrpc": "2.0", "id": 1, "result": {"data": [cycle_event]}},
            {"jsonrpc": "2.0", "id": 1, "result": {"data": []}},
        ],
        expect_status="used_flash_info",
        validator=lambda result, combined: result.returncode == 0 and "INFO: latest rebalance used flash path" in combined,
    )


def experiment_monitor_json_payload(tmp_dir: Path):
    cycle_event = {
        "type": "0xpackage::entrypoints::CycleEvent",
        "timestampMs": str(int(datetime.now(timezone.utc).timestamp() * 1000)),
        "parsedJson": {
            "spot_price": 100000,
            "moved_usdc": 0,
            "bounty_usdc": 0,
            "regime_code": 1,
            "only_unwind": False,
            "safe_cycles_since_storm": 2,
            "treasury_usdc": 500,
            "deployed_usdc": 500,
            "ready_usdc": 200,
            "pending_usdc": 150,
            "used_flash": False,
            "total_assets": 1000,
        },
    }
    server, rpc_url = start_rpc_server(responses=[
        {"jsonrpc": "2.0", "id": 1, "result": {"data": [cycle_event]}},
        {"jsonrpc": "2.0", "id": 1, "result": {"data": []}},
    ])
    try:
        manifest_path = tmp_dir / "monitor_json_payload" / "manifest.json"
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
            "--json",
        ])
        try:
            payload = json.loads(result.stdout)
        except Exception:
            payload = {}
        passed = (
            result.returncode == 0
            and payload.get("summary", {}).get("status") == "ok"
            and payload.get("metrics", {}).get("queue_pressure_bps") == 3500
            and payload.get("metrics", {}).get("reserve_gap_usdc") == 0
        )
        return {
            "name": "monitor_json_payload",
            "command": "monitor_sui.py --json",
            "expected_status": "structured_payload",
            "actual_status": "pass" if passed else "fail",
            "pass": passed,
            "returncode": result.returncode,
            "stdout": tail(result.stdout),
            "stderr": tail(result.stderr),
            "artifact": str(manifest_path),
        }
    finally:
        server.shutdown()
        server.server_close()


def experiment_keeper_blocked_low_gas(tmp_dir: Path):
    name = "keeper_blocked_low_gas"
    fake_bin = tmp_dir / name / "fakebin"
    make_fake_sui_bin(
        fake_bin,
        active_env="testnet",
        active_address="0xkeeper",
        gas_payload={"data": [{"gasCoinId": "0xgas", "mistBalance": "1000000"}]},
    )
    env = os.environ.copy()
    env["PATH"] = str(fake_bin) + os.pathsep + env.get("PATH", "")
    env["PATHEXT"] = ".BAT;.CMD;.EXE;.COM"
    env["SUI_BIN"] = fake_sui_executable(fake_bin)
    server, rpc_url = start_rpc_server(responses=[
        {"jsonrpc": "2.0", "id": 1, "result": {"data": [{
            "type": "0xpackage::entrypoints::CycleEvent",
            "timestampMs": str(int(datetime.now(timezone.utc).timestamp() * 1000)),
            "parsedJson": {
                "spot_price": 100000,
                "moved_usdc": 0,
                "bounty_usdc": 0,
                "regime_code": 1,
                "only_unwind": False,
                "safe_cycles_since_storm": 2,
                "treasury_usdc": 500,
                "deployed_usdc": 500,
                "ready_usdc": 120,
                "pending_usdc": 80,
                "used_flash": False,
                "total_assets": 1000,
            },
        }]}},
        {"jsonrpc": "2.0", "id": 1, "result": {"data": []}},
    ])
    try:
        manifest_path = tmp_dir / name / "manifest.json"
        log_path = tmp_dir / name / "keeper.jsonl"
        write_json(manifest_path, base_manifest("testnet"))
        result = run_cmd([
            sys.executable,
            "scripts/keeper_daemon.py",
            "--manifest",
            str(manifest_path),
            "--rpc-url",
            rpc_url,
            "--once",
            "--spot-price",
            "100000",
            "--log-out",
            str(log_path),
        ], env=env)
        try:
            payload = json.loads(result.stdout)
        except Exception:
            payload = {}
        passed = payload.get("status") == "blocked_low_gas" and "queue_pressure" in payload.get("reasons", [])
        return {
            "name": name,
            "command": "keeper_daemon.py",
            "expected_status": "blocked_low_gas",
            "actual_status": "pass" if passed else "fail",
            "pass": passed,
            "returncode": result.returncode,
            "stdout": tail(result.stdout),
            "stderr": tail(result.stderr),
            "artifact": str(log_path),
        }
    finally:
        server.shutdown()
        server.server_close()


def experiment_fetch_http_json_price(tmp_dir: Path):
    name = "fetch_http_json_price"
    price_path = tmp_dir / name / "price.json"
    write_json(price_path, {"data": {"price": 1.2345}})
    result = run_cmd([
        sys.executable,
        "scripts/fetch_spot_price.py",
        "--source",
        "http-json",
        "--http-json-url",
        price_path.resolve().as_uri(),
        "--http-json-path",
        "data.price",
    ])
    passed = result.returncode == 0 and result.stdout.strip() == "1234500000"
    return {
        "name": name,
        "command": "fetch_spot_price.py",
        "expected_status": "1234500000",
        "actual_status": result.stdout.strip(),
        "pass": passed,
        "returncode": result.returncode,
        "stdout": tail(result.stdout),
        "stderr": tail(result.stderr),
        "artifact": str(price_path),
    }


def experiment_keeper_external_price_source(tmp_dir: Path):
    name = "keeper_external_price_source"
    fake_bin = tmp_dir / name / "fakebin"
    make_fake_sui_bin(
        fake_bin,
        active_env="testnet",
        active_address="0xkeeper",
        gas_payload={"data": [{"gasCoinId": "0xgas", "mistBalance": "5000000000"}]},
    )
    env = os.environ.copy()
    env["PATH"] = str(fake_bin) + os.pathsep + env.get("PATH", "")
    env["PATHEXT"] = ".BAT;.CMD;.EXE;.COM"
    env["SUI_BIN"] = fake_sui_executable(fake_bin)
    price_path = tmp_dir / name / "price.json"
    manifest_path = tmp_dir / name / "manifest.json"
    log_path = tmp_dir / name / "keeper.jsonl"
    write_json(price_path, {"data": {"price": 1.015}})
    write_json(manifest_path, {**base_manifest("testnet"), "cetus_pool_id": "0x0", "config": {"cetus_pool_id": "0x0"}})
    server, rpc_url = start_rpc_server(responses=[
        {"jsonrpc": "2.0", "id": 1, "result": {"data": [{
            "type": "0xpackage::entrypoints::CycleEvent",
            "timestampMs": str(int(datetime.now(timezone.utc).timestamp() * 1000)),
            "parsedJson": {
                "spot_price": 100000,
                "moved_usdc": 0,
                "bounty_usdc": 0,
                "regime_code": 1,
                "only_unwind": False,
                "safe_cycles_since_storm": 2,
                "treasury_usdc": 500,
                "deployed_usdc": 500,
                "ready_usdc": 120,
                "pending_usdc": 80,
                "used_flash": False,
                "total_assets": 1000,
            },
        }]}},
        {"jsonrpc": "2.0", "id": 1, "result": {"data": []}},
    ])
    try:
        result = run_cmd([
            sys.executable,
            "scripts/keeper_daemon.py",
            "--manifest",
            str(manifest_path),
            "--rpc-url",
            rpc_url,
            "--once",
            "--price-source",
            "http-json",
            "--http-json-url",
            price_path.resolve().as_uri(),
            "--http-json-path",
            "data.price",
            "--log-out",
            str(log_path),
        ], env=env)
        try:
            payload = json.loads(result.stdout)
        except Exception:
            payload = {}
        passed = (
            payload.get("status") == "dry_run_ready"
            and payload.get("price_source") == "http-json"
            and payload.get("spot_price") == 1015000000
        )
        return {
            "name": name,
            "command": "keeper_daemon.py --price-source http-json",
            "expected_status": "dry_run_ready",
            "actual_status": payload.get("status", "parse_failed"),
            "pass": passed,
            "returncode": result.returncode,
            "stdout": tail(result.stdout),
            "stderr": tail(result.stderr),
            "artifact": str(log_path),
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

    payload = {"digest": "FAKE_SYNC_DIGEST"}
    results = [
        run_bridge_experiment("bridge_blocked_bad_report_status", tmp_dir, {**ok_scallop_report(), "status": "failed"}, expect_status="blocked_bad_report_status"),
        run_bridge_experiment("bridge_blocked_cross_network", tmp_dir, ok_scallop_report(env="mainnet"), expect_status="blocked_cross_network"),
        run_bridge_experiment("bridge_blocked_wrong_active_env", tmp_dir, ok_scallop_report(env="testnet"), fake_env="mainnet", expect_status="blocked_wrong_active_env"),
        run_bridge_experiment("bridge_blocked_non_isolated_wallet_state", tmp_dir, ok_scallop_report(env="testnet", before=25, after_deposit=125, after_withdraw=0), expect_status="blocked_non_isolated_wallet_state"),
        experiment_bridge_ok(tmp_dir),
        experiment_smoke_blocked(tmp_dir),
        experiment_monitor_no_events(tmp_dir),
        experiment_monitor_rpc_error(tmp_dir),
        experiment_monitor_malformed_json(tmp_dir),
        experiment_monitor_pressure(tmp_dir),
        experiment_monitor_stale_cycle(tmp_dir),
        experiment_monitor_used_flash(tmp_dir),
        experiment_monitor_json_payload(tmp_dir),
        experiment_keeper_blocked_low_gas(tmp_dir),
        experiment_fetch_http_json_price(tmp_dir),
        experiment_keeper_external_price_source(tmp_dir),
    ]

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
