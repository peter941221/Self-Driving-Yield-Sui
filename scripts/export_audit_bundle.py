#!/usr/bin/env python3
import argparse
import hashlib
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FINAL_MANIFEST = ROOT / "out" / "deployments" / "testnet_final_release_v2.json"
DEFAULT_FINAL_CANDIDATE = ROOT / "out" / "deployments" / "testnet_final_release_v2_final_release_candidate.json"
DEFAULT_REPORTS = [
    ROOT / "out" / "reports" / "testnet_final_release_v2_same_network_20260309T1214Z.json",
    ROOT / "out" / "reports" / "testnet_final_release_v2_pressure_20260309T1228Z.json",
    ROOT / "out" / "reports" / "final_release_dry_run_20260309T1232Z.json",
]
DEFAULT_DOCS = [
    ROOT / "README.md",
    ROOT / "reference" / "ASSURANCE_BOARD.md",
    ROOT / "reference" / "CHAOS_MATRIX.md",
    ROOT / "formal" / "PROOF_MATRIX.md",
]


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def copy_into_bundle(src, bundle_root):
    relative = src.resolve().relative_to(ROOT.resolve())
    dest = bundle_root / relative
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)
    return relative.as_posix(), dest


def existing_paths(paths):
    return [path for path in paths if path.exists()]


def main():
    parser = argparse.ArgumentParser(description="Copy the current release evidence into a single local audit bundle and generate an index with hashes")
    parser.add_argument("--manifest", action="append", default=[], help="Manifest path to include; pass multiple times")
    parser.add_argument("--report", action="append", default=[], help="Report path to include; pass multiple times")
    parser.add_argument("--doc", action="append", default=[], help="Doc path to include; pass multiple times")
    parser.add_argument("--bundle-dir", default="", help="Output directory; defaults to out/bundles/audit_<timestamp>")
    parser.add_argument("--zip", action="store_true", help="Also create a .zip next to the bundle directory")
    args = parser.parse_args()

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    bundle_root = Path(args.bundle_dir) if args.bundle_dir else ROOT / "out" / "bundles" / f"audit_{timestamp}"
    bundle_root.mkdir(parents=True, exist_ok=True)

    manifests = existing_paths([Path(path) for path in args.manifest]) if args.manifest else existing_paths([DEFAULT_FINAL_MANIFEST, DEFAULT_FINAL_CANDIDATE])
    reports = existing_paths([Path(path) for path in args.report]) if args.report else existing_paths(DEFAULT_REPORTS)
    docs = existing_paths([Path(path) for path in args.doc]) if args.doc else existing_paths(DEFAULT_DOCS)

    files = []
    for category, paths in (("manifest", manifests), ("report", reports), ("doc", docs)):
        for src in paths:
            relative, dest = copy_into_bundle(src, bundle_root)
            files.append({
                "category": category,
                "source": str(src.resolve()),
                "bundle_path": relative,
                "size_bytes": dest.stat().st_size,
                "sha256": sha256_file(dest),
            })

    index = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "bundle_root": str(bundle_root.resolve()),
        "file_count": len(files),
        "files": files,
    }

    index_path = bundle_root / "bundle_index.json"
    index_path.write_text(json.dumps(index, indent=2), encoding="utf-8")

    summary_lines = [
        "# Audit Bundle",
        "",
        f"- Created: `{index['timestamp_utc']}`",
        f"- Bundle root: `{bundle_root.resolve()}`",
        f"- File count: `{len(files)}`",
        "",
        "## Included Files",
        "",
    ]
    for item in files:
        summary_lines.append(f"- `{item['category']}` `{item['bundle_path']}` sha256=`{item['sha256']}`")
    (bundle_root / "bundle_summary.md").write_text("\n".join(summary_lines) + "\n", encoding="utf-8")

    zip_path = ""
    if args.zip:
        archive_base = str(bundle_root)
        zip_path = shutil.make_archive(archive_base, "zip", root_dir=bundle_root)
        index["zip_path"] = zip_path
        index_path.write_text(json.dumps(index, indent=2), encoding="utf-8")

    print(json.dumps({
        "status": "ok",
        "bundle_root": str(bundle_root.resolve()),
        "index": str(index_path.resolve()),
        "file_count": len(files),
        "zip_path": zip_path,
    }, indent=2))


if __name__ == "__main__":
    main()
