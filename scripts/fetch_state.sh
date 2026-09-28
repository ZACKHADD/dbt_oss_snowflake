#!/usr/bin/env bash
set -euo pipefail

ENVNAME="$1"
STATEDIR="$2"
PREFIX="dbt-state-${ENVNAME}-"

mkdir -p "$STATEDIR"
rm -f "$STATEDIR"/*.json

if [ -z "${GITHUB_REPOSITORY:-}" ] || ! command -v gh >/dev/null 2>&1; then
  echo "STATE-ABSENT (no gh CLI / GITHUB_REPOSITORY)"
  exit 0
fi

ART=$(gh api --paginate "repos/${GITHUB_REPOSITORY}/actions/artifacts?per_page=100" \
  --jq "[.artifacts[] | select(.name | startswith(\"${PREFIX}\")) | select(.expired == false)] | sort_by(.created_at)[-1]" 2>/dev/null || true)

if [ -z "$ART" ] || [ "$ART" = "null" ]; then
  echo "STATE-ABSENT (no artifact ${PREFIX}*)"
  exit 0
fi

ID=$(printf '%s' "$ART" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
ZIP="$RUNNER_TEMP/${ENVNAME}-state.zip"

curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/artifacts/${ID}/zip" -o "$ZIP"

rm -rf "$STATEDIR"/*
cd "$STATEDIR"
python3 - "$ZIP" <<'PY'
import sys, zipfile
zp = sys.argv[1]
with zipfile.ZipFile(zp) as z:
    z.extractall(".")
PY

if [ -f "$STATEDIR/manifest.json" ] && [ -f "$STATEDIR/run_results.json" ]; then
  echo "STATE-FROM-GHA (artifact ${PREFIX}*)"
else
  echo "STATE-ABSENT (artifact ${PREFIX}* incomplete)"
  exit 0
fi