#!/usr/bin/env bash
set -euo pipefail

APP="$1"
REV="$2"

if [ "${ARGOCD_VERIFY_REQUIRED:-false}" != "true" ]; then
  echo "SKIP argo verify (ARGOCD_VERIFY_REQUIRED != true) app=${APP} target=${REV}"
  exit 0
fi

: "${ARGOCD_SERVER:?ARGOCD_SERVER is required}"
: "${ARGOCD_AUTH_TOKEN:?ARGOCD_AUTH_TOKEN is required}"

URL="https://${ARGOCD_SERVER}/api/v1/applications/${APP}"

for i in $(seq 1 30); do
  RES=$(curl -fsS -H "Authorization: Bearer ${ARGOCD_AUTH_TOKEN}" "$URL" 2>/dev/null || echo '{}')
  HEALTH=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print((d.get('status',{}).get('health',{}) or {}).get('status',''))" "$RES")
  SYNC=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print((d.get('status',{}).get('sync',{}) or {}).get('status',''))" "$RES")
  RUN=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print((d.get('status',{}).get('sync',{}) or {}).get('revision',''))" "$RES")
  echo "argo app=${APP} health=${HEALTH} sync=${SYNC} revision=${RUN}"
  if [ "$HEALTH" = "Healthy" ] && [ "$SYNC" = "Synced" ] && [ "${RUN:0:12}" = "${REV:0:12}" ]; then
    echo "ARGO-SYNC-OK"
    exit 0
  fi
  sleep 10
done

echo "ARGO-SYNC-TIMEOUT app=${APP}"
exit 1