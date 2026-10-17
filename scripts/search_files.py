#!/usr/bin/env python3
"""
CLI Utility: Fast File Search for OCR to Excel Uploads & Exports
Allows searching by LR Number, Unique ID, or Date directly from the command line.

Usage:
  python scripts/search_files.py --lr 32754
  python scripts/search_files.py --id LR_20261011_221530
  python scripts/search_files.py --id EXP_20261011_222010
  python scripts/search_files.py --recent
  python scripts/search_files.py BNF
"""

import os
import sys
import argparse
from datetime import datetime, timedelta

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKEND_DIR = os.path.join(BASE_DIR, "backend")
UPLOADS_DIR = os.path.join(BACKEND_DIR, "uploads")
EXPORTS_DIR = os.path.join(BACKEND_DIR, "exports")


def format_size(size_bytes: int) -> str:
    """Formats file size into human-readable string."""
    if size_bytes < 1024:
        return f"{size_bytes} B"
    elif size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.1f} KB"
    else:
        return f"{size_bytes / (1024 * 1024):.1f} MB"


def scan_directory(directory: str, file_type_label: str) -> list[dict]:
    """Scans a directory and returns file metadata dictionaries."""
    results = []
    if not os.path.exists(directory):
        return results

    for root, _, files in os.walk(directory):
        # Exclude internal snapshot subdirectories from simple search
        if "snapshots" in root or "metadata" in root:
            continue
        for f in files:
            full_path = os.path.join(root, f)
            try:
                st = os.stat(full_path)
                mod_time = datetime.fromtimestamp(st.st_mtime)
                results.append({
                    "name": f,
                    "path": full_path,
                    "rel_path": os.path.relpath(full_path, BASE_DIR).replace("\\", "/"),
                    "size": st.st_size,
                    "size_str": format_size(st.st_size),
                    "mtime": mod_time,
                    "mtime_str": mod_time.strftime("%Y-%m-%d %H:%M:%S"),
                    "type": file_type_label,
                })
            except Exception:
                pass
    return results


def main():
    parser = argparse.ArgumentParser(
        description="Search uploaded LR documents and exported Excel files by LR Number, Unique ID, or Date."
    )
    parser.add_argument("query", nargs="?", default="", help="Generic search keyword (substring in filename)")
    parser.add_argument("--lr", help="Filter by LR / Bilty / GR number (e.g. --lr 32754)")
    parser.add_argument("--id", help="Filter by Unique ID prefix (e.g. --id LR_20261011 or --id EXP_20261011)")
    parser.add_argument("--type", choices=["all", "uploads", "exports"], default="all", help="Limit search scope")
    parser.add_argument("--recent", nargs="?", const=24, type=int, help="Show files created in the last N hours (default: 24)")

    args = parser.parse_args()

    files = []
    if args.type in ("all", "uploads"):
        files.extend(scan_directory(UPLOADS_DIR, "Upload (LR)"))
    if args.type in ("all", "exports"):
        files.extend(scan_directory(EXPORTS_DIR, "Export (Excel)"))

    # Apply filters
    filtered = []
    now = datetime.now()

    for item in files:
        fname = item["name"].lower()

        # Filter by LR Number
        if args.lr:
            lr_clean = args.lr.lower().strip()
            if lr_clean not in fname:
                continue

        # Filter by Unique ID
        if args.id:
            id_clean = args.id.lower().strip()
            if id_clean not in fname:
                continue

        # Filter by Recent hours
        if args.recent is not None:
            cutoff = now - timedelta(hours=args.recent)
            if item["mtime"] < cutoff:
                continue

        # Filter by Generic Query
        if args.query:
            q_clean = args.query.lower().strip()
            if q_clean not in fname:
                continue

        filtered.append(item)

    # Sort newest first
    filtered.sort(key=lambda x: x["mtime"], reverse=True)

    print("=" * 105)
    print("  OCR to Excel - File Search Results")
    print(f"  Criteria: LR={args.lr or 'Any'}, ID={args.id or 'Any'}, Recent={args.recent or 'Any'}, Query={args.query or 'None'}")
    print(f"  Matched: {len(filtered)} file(s)")
    print("=" * 105)

    if not filtered:
        print("  No matching files found.")
        print("\n  Quick PowerShell search tip:")
        term = args.lr or args.query or "*"
        print(f"    Get-ChildItem backend/uploads -Filter '*{term}*'")
        print(f"    Get-ChildItem backend/exports -Filter '*{term}*'")
        print("=" * 105)
        return

    # Print table header
    print(f"{'TYPE':<15} | {'FILE NAME':<55} | {'SIZE':<9} | {'MODIFIED AT':<19}")
    print("-" * 105)
    for f in filtered:
        fname_disp = f['name'] if len(f['name']) <= 53 else f['name'][:50] + "..."
        print(f"{f['type']:<15} | {fname_disp:<55} | {f['size_str']:<9} | {f['mtime_str']:<19}")
        print(f"                |-> Path: {f['rel_path']}")

    print("=" * 105)


if __name__ == "__main__":
    main()
