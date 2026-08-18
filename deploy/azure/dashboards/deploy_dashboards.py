#!/usr/bin/env python3
"""Create or update generated Azure Workbooks without running Terraform."""

import argparse
import json
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--resource-group", required=True)
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--subscription")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    manifest = json.loads((args.input_dir / "manifest.json").read_text())
    subscription = args.subscription
    if not subscription and args.dry_run:
        subscription = "CURRENT-SUBSCRIPTION"
    elif not subscription:
        subscription = subprocess.check_output(["az", "account", "show", "--query", "id", "-o", "tsv"], text=True).strip()
    for service, workbook_id in manifest.items():
        resource_id = f"/subscriptions/{subscription}/resourceGroups/{args.resource_group}/providers/Microsoft.Insights/workbooks/{workbook_id}"
        if args.dry_run:
            print(f"PUT {resource_id} <- {args.input_dir / f'otel-demo-{service}.json'}")
            continue
        subprocess.run([
            "az", "rest", "--method", "put",
            "--url", f"https://management.azure.com{resource_id}?api-version=2022-04-01",
            "--body", f"@{args.input_dir / f'otel-demo-{service}.json'}",
            "--output", "none",
        ], check=True)
        print(f"updated {service}: {workbook_id}")


if __name__ == "__main__":
    main()
