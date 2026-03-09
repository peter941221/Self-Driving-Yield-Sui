#!/usr/bin/env python3
import argparse
import datetime
import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

REQUIRED_FIELDS = [
    "network",
    "package_id",
    "base_type",
    "vault_id",
    "queue_id",
    "config_id",
    "admin_cap_id",
    "cetus_pool_id",
    "lending_market_id",
    "perps_market_id",
    "flashloan_provider_id",
]

ADDRESS_FIELDS = [
    "package_id",
    "vault_id",
    "queue_id",
    "config_id",
    "admin_cap_id",
    "cetus_pool_id",
    "lending_market_id",
    "perps_market_id",
    "flashloan_provider_id",
]


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def resolve_cmd(cmd):
    if cmd and cmd[0] == "sui" and os.environ.get("SUI_BIN"):
        return [os.environ["SUI_BIN"], *cmd[1:]]
    return cmd


def try_run(cmd, cwd=ROOT):
    resolved = resolve_cmd(list(cmd))
    result = subprocess.run(resolved, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def utc_now_iso():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()


def normalize_address(value):
    if not isinstance(value, str) or not value.startswith("0x"):
        raise ValueError(f"Expected hex address, got: {value}")
    hex_part = value[2:]
    if not hex_part:
        raise ValueError(f"Expected non-empty hex address, got: {value}")
    int(hex_part, 16)
    if len(hex_part) > 64:
        raise ValueError(f"Address too long: {value}")
    return "0x" + hex_part.lower().zfill(64)


def coalesce_manifest_field(manifest, field, default=None):
    if field in manifest and manifest[field] not in (None, ""):
        return manifest[field]
    config = manifest.get("config", {})
    if isinstance(config, dict) and field in config and config[field] not in (None, ""):
        return config[field]
    return default


def git_commit():
    output = try_run(["git", "rev-parse", "HEAD"])
    return output or ""


def git_status_short():
    output = try_run(["git", "status", "--short"])
    return output or ""


def active_env():
    return try_run(["sui", "client", "active-env"]) or ""


def active_address():
    return try_run(["sui", "client", "active-address"]) or ""


def build_release_manifest(manifest, report_paths, source_manifest_path: Path):
    release_manifest = {
        "network": manifest.get("network", ""),
        "sender": manifest.get("sender", ""),
        "package_id": manifest.get("package_id", ""),
        "base_type": manifest.get("base_type", ""),
        "vault_id": manifest.get("vault_id", ""),
        "queue_id": manifest.get("queue_id", ""),
        "config_id": manifest.get("config_id", ""),
        "admin_cap_id": manifest.get("admin_cap_id", ""),
        "cetus_pool_id": coalesce_manifest_field(manifest, "cetus_pool_id", "0x0"),
        "lending_market_id": coalesce_manifest_field(manifest, "lending_market_id", "0x0"),
        "perps_market_id": coalesce_manifest_field(manifest, "perps_market_id", "0x0"),
        "flashloan_provider_id": coalesce_manifest_field(manifest, "flashloan_provider_id", "0x0"),
        "min_cycle_interval_ms": coalesce_manifest_field(manifest, "min_cycle_interval_ms", 0),
        "min_snapshot_interval_ms": coalesce_manifest_field(manifest, "min_snapshot_interval_ms", 0),
        "sealed": bool(coalesce_manifest_field(manifest, "sealed", False)),
        "publish_digest": manifest.get("publish_digest"),
        "bootstrap_digest": manifest.get("bootstrap_digest"),
        "seal_digest": manifest.get("seal_digest"),
        "published_at_utc": manifest.get("published_at_utc") or utc_now_iso(),
        "git_commit": manifest.get("git_commit") or git_commit(),
        "latest_report": str(report_paths[-1].as_posix()) if report_paths else manifest.get("latest_report", ""),
        "evidence_reports": [str(path.as_posix()) for path in report_paths],
        "source_manifest": str(source_manifest_path.as_posix()),
        # Keep the legacy nested config mirror so current scripts remain compatible.
        "config": {
            "min_cycle_interval_ms": coalesce_manifest_field(manifest, "min_cycle_interval_ms", 0),
            "min_snapshot_interval_ms": coalesce_manifest_field(manifest, "min_snapshot_interval_ms", 0),
            "cetus_pool_id": coalesce_manifest_field(manifest, "cetus_pool_id", "0x0"),
            "lending_market_id": coalesce_manifest_field(manifest, "lending_market_id", "0x0"),
            "perps_market_id": coalesce_manifest_field(manifest, "perps_market_id", "0x0"),
            "flashloan_provider_id": coalesce_manifest_field(manifest, "flashloan_provider_id", "0x0"),
            "sealed": bool(coalesce_manifest_field(manifest, "sealed", False)),
        },
    }

    for field in ADDRESS_FIELDS:
        release_manifest[field] = normalize_address(release_manifest[field])
    if release_manifest["sender"]:
        release_manifest["sender"] = normalize_address(release_manifest["sender"])
    for field in ("cetus_pool_id", "lending_market_id", "perps_market_id", "flashloan_provider_id"):
        release_manifest["config"][field] = release_manifest[field]
    return release_manifest


def validate_release_manifest(release_manifest, original_manifest, report_payloads):
    checks = []

    def add(name, status, detail):
        checks.append({"name": name, "status": status, "detail": detail})

    missing = [field for field in REQUIRED_FIELDS if not release_manifest.get(field)]
    if missing:
        add("required_fields", "block", f"Missing required fields: {', '.join(missing)}")
    else:
        add("required_fields", "pass", "All required manifest fields are present")

    try:
        for field in ADDRESS_FIELDS:
            normalize_address(release_manifest[field])
        if release_manifest.get("sender"):
            normalize_address(release_manifest["sender"])
        add("address_shape", "pass", "All manifest address fields are normalized hex addresses")
    except ValueError as exc:
        add("address_shape", "block", str(exc))

    nested_config = original_manifest.get("config", {})
    if isinstance(nested_config, dict):
        mismatches = []
        for field in ("cetus_pool_id", "lending_market_id", "perps_market_id", "flashloan_provider_id", "sealed"):
            nested_value = nested_config.get(field)
            if nested_value is None:
                continue
            normalized_nested = nested_value
            if field != "sealed":
                normalized_nested = normalize_address(nested_value)
            if release_manifest[field] != normalized_nested:
                mismatches.append(field)
        if mismatches:
            add("legacy_config_mirror", "block", f"Top-level and nested config values diverge: {', '.join(mismatches)}")
        else:
            add("legacy_config_mirror", "pass", "Top-level release fields match the legacy config mirror")
    else:
        add("legacy_config_mirror", "warn", "Manifest does not include a nested config mirror")

    if release_manifest["sealed"]:
        add("sealed", "pass", "Manifest is sealed and can satisfy the release freeze gate")
    else:
        add("sealed", "block", "Manifest is not sealed")

    if release_manifest["sealed"] and release_manifest.get("seal_digest"):
        add("seal_digest", "pass", "Seal digest is present")
    elif release_manifest["sealed"]:
        add("seal_digest", "block", "Manifest is sealed but seal_digest is missing")
    else:
        add("seal_digest", "warn", "Seal digest skipped because manifest is not sealed")

    non_zero_adapters = [
        field for field in ("cetus_pool_id", "lending_market_id", "perps_market_id", "flashloan_provider_id")
        if int(release_manifest[field], 16) != 0
    ]
    if non_zero_adapters:
        add("adapter_intent", "pass", f"Non-zero adapters configured: {', '.join(non_zero_adapters)}")
    else:
        add("adapter_intent", "warn", "All adapters are disabled with 0x0")

    for report_payload in report_payloads:
        report_env = report_payload["payload"].get("env")
        if report_env and report_env != release_manifest["network"]:
            add("report_network", "block", f"Report {report_payload['path']} env {report_env} != manifest network {release_manifest['network']}")
            break
    else:
        add("report_network", "pass", "All provided reports match the manifest network when env is present")

    current_env = active_env()
    if current_env:
        if current_env == release_manifest["network"]:
            add("active_env", "pass", f"Active env matches manifest network: {current_env}")
        else:
            add("active_env", "block", f"Active env {current_env} != manifest network {release_manifest['network']}")
    else:
        add("active_env", "warn", "Unable to determine active Sui environment")

    current_address = active_address()
    if current_address and release_manifest.get("sender"):
        try:
            current_address = normalize_address(current_address)
            if current_address == release_manifest["sender"]:
                add("active_address", "pass", f"Active address matches manifest sender: {current_address}")
            else:
                add("active_address", "block", f"Active address {current_address} != manifest sender {release_manifest['sender']}")
        except ValueError as exc:
            add("active_address", "warn", f"Unable to normalize active address: {exc}")
    else:
        add("active_address", "warn", "Unable to compare active address to manifest sender")

    worktree = git_status_short()
    if worktree:
        add("git_worktree", "block", "Git worktree is dirty; final release should come from a clean commit")
    else:
        add("git_worktree", "pass", "Git worktree is clean")

    if release_manifest.get("git_commit"):
        add("git_commit", "pass", f"Git commit recorded: {release_manifest['git_commit']}")
    else:
        add("git_commit", "warn", "Git commit is missing from the release manifest")

    return checks


def main():
    parser = argparse.ArgumentParser(description="Run a local final-release closure dry-run without publishing")
    parser.add_argument("--manifest", required=True, help="Path to the source deployment manifest")
    parser.add_argument("--report", action="append", default=[], help="Evidence report path to include; pass multiple times")
    parser.add_argument("--release-manifest-out", default="", help="Path for the normalized release manifest")
    parser.add_argument("--dry-run-report-out", default="", help="Path for the dry-run report JSON")
    args = parser.parse_args()

    manifest_path = Path(args.manifest).resolve()
    report_paths = [Path(path).resolve() for path in args.report]
    release_manifest_out = (
        Path(args.release_manifest_out).resolve()
        if args.release_manifest_out
        else ROOT / "out" / "deployments" / f"{manifest_path.stem}_final_release_candidate.json"
    )
    dry_run_report_out = (
        Path(args.dry_run_report_out).resolve()
        if args.dry_run_report_out
        else ROOT / "out" / "reports" / f"final_release_dry_run_{datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
    )

    manifest = load_json(manifest_path)
    report_payloads = []
    missing_reports = []
    for report_path in report_paths:
        if not report_path.exists():
            missing_reports.append(str(report_path))
            continue
        report_payloads.append({"path": str(report_path.as_posix()), "payload": load_json(report_path)})

    release_manifest = build_release_manifest(manifest, [Path(item["path"]) for item in report_payloads], manifest_path)
    checks = validate_release_manifest(release_manifest, manifest, report_payloads)
    if missing_reports:
        checks.append({
            "name": "report_files",
            "status": "block",
            "detail": f"Missing report files: {', '.join(missing_reports)}",
        })
    else:
        checks.append({
            "name": "report_files",
            "status": "pass",
            "detail": f"All requested report files exist ({len(report_payloads)})",
        })

    release_manifest_out.parent.mkdir(parents=True, exist_ok=True)
    release_manifest_out.write_text(json.dumps(release_manifest, indent=2), encoding="utf-8")

    blocking = [check for check in checks if check["status"] == "block"]
    warnings = [check for check in checks if check["status"] == "warn"]
    dry_run_report = {
        "timestamp_utc": utc_now_iso(),
        "status": "ok",
        "final_release_readiness": "blocked" if blocking else "ready",
        "source_manifest": str(manifest_path.as_posix()),
        "release_manifest_out": str(release_manifest_out.as_posix()),
        "dry_run_scope": "local closure check only; no chain mutation performed",
        "checks": checks,
        "blocking_count": len(blocking),
        "warning_count": len(warnings),
        "evidence_reports": [item["path"] for item in report_payloads],
    }

    dry_run_report_out.parent.mkdir(parents=True, exist_ok=True)
    dry_run_report_out.write_text(json.dumps(dry_run_report, indent=2), encoding="utf-8")

    print(json.dumps(dry_run_report, indent=2))


if __name__ == "__main__":
    main()
