#!/usr/bin/env bash
set -euo pipefail

DB="${CLEANUP_DATABASE:-DEV_SANDBOX}"
AGE="${CLEANUP_MIN_AGE_DAYS:-14}"
PROJ="${DBT_PROJECT_PATH:-dbt_openfood}"

cd "$(dirname "$0")/.."
cd "$PROJ"

uv run dbt run-operation cleanup_developer_schemas \
  --args "{\"database\": \"${DB}\", \"min_age_days\": ${AGE}}" \
  --target dev