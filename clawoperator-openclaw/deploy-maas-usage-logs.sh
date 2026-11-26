#!/usr/bin/env bash
# deploy-maas-usage-logs.sh — log-based MaaS usage dashboards (RHOAI 3.5+).
#
# Step 6 of the RHOAI MaaS guide, backed by this cluster's ODF/NooBaa storage
# instead of the MinIO the guide uses for non-production. Adds per-request
# token/user/subscription detail on top of the existing metric-based Usage tab.
#
# Enabling it installs an EnvoyFilter on openshift-ingress — the gateway all
# inference goes through. It is the log source, so it cannot be skipped. Do not
# run this just before a demo; the script re-tests inference afterwards.
#
# Usage:
#   ./deploy-maas-usage-logs.sh                  # storage, enable, verify
#   ./deploy-maas-usage-logs.sh --check          # report only
#   ./deploy-maas-usage-logs.sh --storage-only   # no EnvoyFilter
#   ./deploy-maas-usage-logs.sh --disable        # roll back

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MON_NS=redhat-ods-monitoring
OBC_NAME=maas-usage-logs
SECRET_NAME=maas-usage-logs-s3
ODF_STORAGE_CLASS=openshift-storage.noobaa.io
MODE=deploy

case "${1:-}" in
  --check)        MODE=check ;;
  --storage-only) MODE=storage ;;
  --disable)      MODE=disable ;;
  "")             ;;
  *) echo "Unknown flag: $1" >&2; exit 1 ;;
esac

for c in oc python3; do command -v "$c" >/dev/null || { echo "Missing $c" >&2; exit 1; }; done
oc whoami >/dev/null || exit 1

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YEL=$'\033[0;33m'; RST=$'\033[0m'
ok()   { echo "  ${GREEN}✓${RST} $*"; }
bad()  { echo "  ${RED}✗${RST} $*"; }
warn() { echo "  ${YEL}!${RST} $*"; }

gateway_ok() {
  local k code domain
  k=$(oc get secret litellm-api-key -n agentic-user1 -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d)
  [[ -z "$k" ]] && { warn "no seat key to test with — check inference by hand"; return 0; }
  domain=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 \
    -H "Authorization: Bearer $k" -H 'Content-Type: application/json' \
    -d '{"model":"'"${LLM_MODEL_NAME:-qwen3-235b-a22b}"'","messages":[{"role":"user","content":"ok"}],"max_tokens":5}' \
    "${MAAS_URL:-https://maas.${domain}}/v1/chat/completions" 2>/dev/null)
  [[ "$code" == "200" ]] && { ok "inference still OK (HTTP 200)"; return 0; }
  bad "INFERENCE RETURNED HTTP $code — roll back: $0 --disable"
  return 1
}

report() {
  echo "── MaaS usage logs ─────────────────────────────────"
  local v ls d
  v=$(oc get configs.maas.opendatahub.io default -o jsonpath='{.spec.usageLogging}' 2>/dev/null)
  [[ "$v" == "true" ]] && ok "usageLogging: true" || bad "usageLogging: ${v:-<unset>}"
  oc get obc "$OBC_NAME" -n "$MON_NS" >/dev/null 2>&1 \
    && ok "OBC $OBC_NAME: $(oc get obc "$OBC_NAME" -n "$MON_NS" -o jsonpath='{.status.phase}' 2>/dev/null)" \
    || bad "OBC $OBC_NAME missing"
  ls=$(oc get lokistack usage -n "$MON_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [[ "$ls" == "True" ]] && ok "LokiStack usage Ready" || bad "LokiStack usage: ${ls:-missing}"
  # Also the rollback indicator: if this lingers after --disable, delete it.
  oc get envoyfilter maas-model-access-logs -n openshift-ingress >/dev/null 2>&1 \
    && ok "EnvoyFilter present" || warn "EnvoyFilter absent (expected until enabled)"
  oc get opentelemetrycollector usage-logs -n "$MON_NS" >/dev/null 2>&1 \
    && ok "collector usage-logs present" || warn "collector usage-logs absent"
  d=$(oc get persesdashboard -n "$MON_NS" --no-headers 2>/dev/null | grep -c 'usage-logs' || true)
  [[ "${d:-0}" -gt 0 ]] && ok "usage-logs dashboards: $d" || warn "no usage-logs dashboards yet"
}

case "$MODE" in
  check) report; exit 0 ;;
  disable)
    oc patch configs.maas.opendatahub.io default --type=merge \
      -p '{"spec":{"usageLogging":false}}' >/dev/null && ok "usageLogging: false"
    sleep 10
    if oc get envoyfilter maas-model-access-logs -n openshift-ingress >/dev/null 2>&1; then
      warn "EnvoyFilter still present — delete it, then re-test inference:"
      echo "    oc delete envoyfilter maas-model-access-logs -n openshift-ingress"
    else
      ok "EnvoyFilter removed"
    fi
    gateway_ok; exit $?
    ;;
esac

echo "── prerequisites ───────────────────────────────────"
# Fail with the fix rather than half-building.
oc get configs.maas.opendatahub.io default >/dev/null 2>&1 \
  || { bad "configs.maas.opendatahub.io/default not found — needs RHOAI 3.5+"; exit 1; }
oc get crd objectbucketclaims.objectbucket.io >/dev/null 2>&1 \
  || { bad "ObjectBucketClaim CRD missing — ODF/NooBaa not installed"; exit 1; }
oc get storageclass "$ODF_STORAGE_CLASS" >/dev/null 2>&1 \
  || { bad "StorageClass $ODF_STORAGE_CLASS missing — MCG side of ODF absent"; exit 1; }
oc get csv -A --no-headers 2>/dev/null | grep -qi 'loki-operator' \
  || { bad "Loki Operator not installed — see the guide's step 6a"; exit 1; }
ok "CR, ODF, StorageClass and Loki Operator present"

echo "── object storage ──────────────────────────────────"
oc apply -f "$SCRIPT_DIR/operator-patches/maas-usage-logs-obc.yaml" >/dev/null
# The ConfigMap and Secret only exist once the claim binds.
BOUND=""
for _ in $(seq 1 36); do
  BOUND=$(oc get obc "$OBC_NAME" -n "$MON_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$BOUND" == "Bound" ]] && break
  sleep 5
done
[[ "$BOUND" == "Bound" ]] || { bad "OBC did not bind in 180s (phase: ${BOUND:-unknown})"; exit 1; }
ok "ObjectBucketClaim bound"

BUCKET=$(oc get cm "$OBC_NAME" -n "$MON_NS" -o jsonpath='{.data.BUCKET_NAME}' 2>/dev/null)
HOST=$(oc get cm "$OBC_NAME" -n "$MON_NS" -o jsonpath='{.data.BUCKET_HOST}' 2>/dev/null)
PORT=$(oc get cm "$OBC_NAME" -n "$MON_NS" -o jsonpath='{.data.BUCKET_PORT}' 2>/dev/null)
REGION=$(oc get cm "$OBC_NAME" -n "$MON_NS" -o jsonpath='{.data.BUCKET_REGION}' 2>/dev/null)
AKID=$(oc get secret "$OBC_NAME" -n "$MON_NS" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d)
ASK=$(oc get secret "$OBC_NAME" -n "$MON_NS" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d)
[[ -n "$BUCKET" && -n "$HOST" && -n "$AKID" && -n "$ASK" ]] \
  || { bad "OBC bound but its ConfigMap/Secret is missing keys"; exit 1; }

# Service host, not the Route: its service-serving cert is what the
# LokiStack's tls.caName trusts. Same reasoning as deploy-logs-loki.sh.
oc create secret generic "$SECRET_NAME" -n "$MON_NS" \
  --from-literal=access_key_id="$AKID" \
  --from-literal=access_key_secret="$ASK" \
  --from-literal=bucketnames="$BUCKET" \
  --from-literal=endpoint="https://${HOST}:${PORT:-443}" \
  --from-literal=region="${REGION:-}" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
ok "storage secret written (credentials not printed)"

oc apply -f "$SCRIPT_DIR/operator-patches/maas-usage-logs-lokistack.yaml" >/dev/null
echo "  waiting for LokiStack usage (up to 300s)…"
oc wait lokistack/usage -n "$MON_NS" \
  --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True --timeout=300s >/dev/null 2>&1 \
  && ok "LokiStack usage Ready" \
  || { bad "LokiStack did not become Ready"; oc get lokistack usage -n "$MON_NS"; exit 1; }

if [[ "$MODE" == storage ]]; then
  echo
  warn "--storage-only: stopping before the EnvoyFilter. Enable when ready:"
  echo "    oc patch configs.maas.opendatahub.io default --type=merge -p '{\"spec\":{\"usageLogging\":true}}'"
  exit 0
fi

echo "── enable usage logging ────────────────────────────"
oc patch configs.maas.opendatahub.io default --type=merge \
  -p '{"spec":{"usageLogging":true}}' >/dev/null && ok "usageLogging: true"
sleep 30

echo "── gateway check ───────────────────────────────────"
gateway_ok || exit 1

echo
report
echo
echo "Drive a few agent turns, then Observe & monitor → Dashboard."
echo "Roll back with: $0 --disable"
