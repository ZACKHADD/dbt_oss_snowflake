#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys

ap = argparse.ArgumentParser()
ap.add_argument("--env", required=True)
ap.add_argument("--target", required=True)
ap.add_argument("--state", required=True)
ap.add_argument("--project", default="dbt_openfood")
a = ap.parse_args()

old_path = f"{a.state}/manifest.json"
new_path = f"{a.project}/target/manifest.json"

try:
    with open(old_path, encoding="utf-8") as f:
        old = json.load(f)
    with open(new_path, encoding="utf-8") as f:
        new = json.load(f)
except FileNotFoundError as e:
    print(f"drop-check: missing manifest {e}; skipping")
    sys.exit(0)


def mtype(v):
    rt = v.get("resource_type", "")
    mat = (v.get("config", {}) or {}).get("materialized", "")
    if rt == "seed" or mat in (
        "table", "incremental", "dynamic_table", "external",
        "materialized_view", "snapshot", "stream",
    ):
        return "table"
    return "view"


keep_rt = ("model", "seed", "snapshot")
old_nodes = {k: v for k, v in old.get("nodes", {}).items() if v.get("resource_type") in keep_rt}
new_nodes = {k: v for k, v in new.get("nodes", {}).items() if v.get("resource_type") in keep_rt}

dropped = []
for k, v in old_nodes.items():
    if k not in new_nodes:
        dropped.append({
            "database": v["database"],
            "schema": v["schema"],
            "identifier": v.get("alias") or v["name"],
            "type": mtype(v),
        })

if not dropped:
    print("no removed nodes in this run")
    sys.exit(0)

print(f"dropping {len(dropped)} removed node(s) from env={a.env}:")
for o in dropped:
    print(f"  {o['database']}.{o['schema']}.{o['identifier']} ({o['type']})")

payload = json.dumps({"objects": dropped})
p = subprocess.run(
    ["uv", "run", "dbt", "run-operation", "drop_objects", "--args", payload, "--target", a.target],
    cwd=a.project,
)
sys.exit(p.returncode)