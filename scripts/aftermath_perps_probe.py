#!/usr/bin/env python3
import argparse
import json
import os
import re
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
POC_DIR = ROOT / "poc" / "aftermath-perps"
DIGEST_PATTERNS = {
    "create_account": re.compile(r"create account tx digest:\s*(\S+)"),
    "deposit": re.compile(r"deposit tx digest:\s*(\S+)"),
    "allocate": re.compile(r"allocate tx digest:\s*(\S+)"),
    "open_short": re.compile(r"open short tx digest:\s*(\S+)"),
    "close": re.compile(r"close tx digest:\s*(\S+)"),
}




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


def active_address():
    return run(["sui", "client", "active-address"])


def ensure_secret_key():
    env_key = os.environ.get("SUI_SECRET_KEY", "").strip()
    if env_key:
        return env_key
    keys = run_json(["sui", "keytool", "list", "--json"])
    active = active_address().lower()
    match = next((item for item in keys if str(item.get("suiAddress", "")).lower() == active), None)
    if not match:
        raise SystemExit(f"Unable to match active address {active} in `sui keytool list --json`")
    exported = run_json(["sui", "keytool", "export", "--key-identity", match["alias"], "--json"])
    return exported["exportedPrivateKey"]


def parse_digests(output):
    found = {}
    for key, pattern in DIGEST_PATTERNS.items():
        match = pattern.search(output)
        if match:
            found[key] = match.group(1)
    return found


def main():
    parser = argparse.ArgumentParser(description="Run the existing Aftermath perps PoC with a funded testnet key and archive a JSON report")
    parser.add_argument("--skip-install", action="store_true", help="Skip `pnpm install` if node_modules already exists")
    parser.add_argument("--report-out", default="")
    args = parser.parse_args()

    report_path = Path(args.report_out) if args.report_out else ROOT / "out" / "reports" / f"aftermath_perps_probe_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    env["SUI_SECRET_KEY"] = ensure_secret_key()

    if not args.skip_install and not (POC_DIR / "node_modules").exists():
        run([resolve_pnpm(), "install"], cwd=POC_DIR, env=env)

    result = subprocess.run([resolve_pnpm(), "run", "poc"], cwd=POC_DIR, capture_output=True, text=True, env=env)
    output = (result.stdout or "") + (("\n" + result.stderr) if result.stderr else "")
    digests = parse_digests(output)

    report = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "address": active_address(),
        "status": "ok" if result.returncode == 0 else "failed",
        "returncode": result.returncode,
        "digests": digests,
        "output": output,
        "working_dir": str(POC_DIR),
    }
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

    if result.returncode != 0:
        raise SystemExit(output.strip() or f"Aftermath perps probe failed. Report written to {report_path}")

    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
