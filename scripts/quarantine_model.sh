#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: quarantine_model.sh schema.model [schema.model ...]"
  exit 1
fi

MODELS_JSON=$(printf '%s\n' "$@" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().split()))")

PROJ="${DBT_PROJECT_PATH:-dbt_openfood}"
cd "$(dirname "$0")/.."
cd "$PROJ"

uv run dbt run-operation quarantine_models --args "{\"models\": ${MODELS_JSON}}"