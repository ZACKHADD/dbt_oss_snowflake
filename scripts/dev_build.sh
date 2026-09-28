#!/usr/bin/env bash
set -euo pipefail

: "${DBT_DEVELOPER_NAME:?set DBT_DEVELOPER_NAME, e.g. DBT_DEVELOPER_NAME=alice}"
PROJ="${DBT_PROJECT_PATH:-dbt_openfood}"

cd "$(dirname "$0")/.."
cd "$PROJ"

SELECTOR="${1:-}"
if [ -n "$SELECTOR" ]; then
  uv run dbt build --target dev_sandbox --select "$SELECTOR"
else
  uv run dbt build --target dev_sandbox
fi