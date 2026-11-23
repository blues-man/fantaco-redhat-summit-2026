#!/usr/bin/env bash
# migrate-traces-to-rhoai-mlflow.sh — point seats at RHOAI MLflow instead of
# the standalone community MLflow.
#
# WHY THIS IS NEEDED AT ALL. OpenClaw cannot talk to RHOAI MLflow directly:
# the gateway container has automountServiceAccountToken off, so it has no
# ServiceAccount token and no service-ca.crt, and RHOAI MLflow requires a
# bearer token over TLS. A collector holds the credential instead and adds the
# two headers MLflow demands (X-MLflow-Workspace, x-mlflow-experiment-id).
# Deploy it first with operator-patches/openclaw-mlflow-trace-collector.yaml.
#
# THE TRAP THAT COST THE MOST TIME. The gateway has HTTP_PROXY/HTTPS_PROXY set
# to instance-proxy, whose allowlist is reconciled by the Claw operator and has
# no field for extra domains. That looks fatal — but the OTLP exporter does NOT
# use the proxy. Proof: the standalone MLflow has never been in the proxy
# allowlist and has been receiving traces for days. Only an egress
# NetworkPolicy is required, and it must select the GATEWAY (app=claw), not the
# proxy. Testing reachability with Node `fetch` is misleading: fetch honours
# HTTP_PROXY and returns "blocked CONNECT to unknown domain" while the real
# exporter path works fine.
#
# Usage:
#   ./migrate-traces-to-rhoai-mlflow.sh 1 105     # migrate a range
#   ./migrate-traces-to-rhoai-mlflow.sh --check   # report where seats point
#   ./migrate-traces-to-rhoai-mlflow.sh --revert 1 105   # back to standalone

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRACE_NS="${TRACE_NS:-openclaw-tracing}"
COLLECTOR="http://openclaw-mlflow-collector.${TRACE_NS}.svc:4318/v1/traces"
STANDALONE="http://mlflow-mlflow.mlflow.svc.cluster.local:5000/v1/traces"
MODE=migrate; START=1; END=105

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)  MODE=check; shift ;;
    --revert) MODE=revert; shift ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) START="$1"; END="${2:?need an end seat}"; shift 2 ;;
  esac
done

command -v oc >/dev/null || { echo "Missing oc" >&2; exit 1; }
oc whoami >/dev/null || exit 1
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YEL=$'\033[0;33m'; RST=$'\033[0m'

current_endpoint() {
  oc exec deployment/instance -n "agentic-user$1" -c gateway -- python3 -c "
import json
print(json.load(open('/home/node/.openclaw/openclaw.json')).get('env',{}).get('OTEL_EXPORTER_OTLP_TRACES_ENDPOINT',''))" 2>/dev/null
}

if [[ "$MODE" == check ]]; then
  echo "── where seats send traces ─────────────────────────"
  rhoai=0; standalone=0; other=0
  for i in $(seq "$START" "$END"); do
    e=$(current_endpoint "$i")
    case "$e" in
      *openclaw-mlflow-collector*) rhoai=$((rhoai+1)) ;;
      *mlflow-mlflow.mlflow*)      standalone=$((standalone+1)) ;;
      *)                           other=$((other+1)); echo "  seat $i: ${e:-<unreadable>}" ;;
    esac
  done
  echo "  ${GREEN}RHOAI MLflow:${RST} $rhoai   ${YEL}standalone:${RST} $standalone   other/unreadable: $other"
  exit 0
fi

TARGET="$COLLECTOR"; LABEL="RHOAI MLflow (via collector)"
if [[ "$MODE" == revert ]]; then TARGET="$STANDALONE"; LABEL="standalone MLflow"; fi
echo "── pointing seats $START..$END at $LABEL ──"

ok=0; fail=0
for i in $(seq "$START" "$END"); do
  NS="agentic-user$i"
  oc get namespace "$NS" >/dev/null 2>&1 || continue

  # Egress policy. Selects app=claw: the GATEWAY opens the connection, because
  # the OTLP exporter bypasses instance-proxy. Harmless when reverting.
  if [[ "$MODE" != revert ]]; then
    oc apply -n "$NS" -f - >/dev/null 2>&1 <<NETPOL
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-instance-to-trace-collector
spec:
  podSelector:
    matchExpressions:
      - key: app
        operator: In
        values: ["claw", "claw-proxy"]
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ${TRACE_NS}
      ports:
        - {port: 4318, protocol: TCP}
        - {port: 4317, protocol: TCP}
NETPOL
  fi

  if oc exec deployment/instance -n "$NS" -c gateway -- python3 -c "
import json
p='/home/node/.openclaw/openclaw.json'
d=json.load(open(p))
d.setdefault('env',{})['OTEL_EXPORTER_OTLP_TRACES_ENDPOINT']='${TARGET}'
json.dump(d,open(p,'w'),indent=2)" >/dev/null 2>&1; then
    ok=$((ok+1)); printf "  [%3d/%3d] %-18s set\r" "$((ok+fail))" "$((END-START+1))" "$NS"
  else
    fail=$((fail+1)); echo "  ${RED}✗${RST} $NS: could not write openclaw.json"
  fi
done
echo
echo "  endpoint written: $ok   failed: $fail"

# Plugins and OTEL config are read at BOOT. Without this the change is inert.
echo "── restarting gateways (config is read at boot) ────"
for i in $(seq "$START" "$END"); do
  oc rollout restart deployment/instance -n "agentic-user$i" >/dev/null 2>&1
done
settled=0
for i in $(seq "$START" "$END"); do
  oc rollout status deployment/instance -n "agentic-user$i" --timeout=240s >/dev/null 2>&1 \
    && settled=$((settled+1))
done
echo "  gateways settled: $settled/$((END-START+1))"
echo
echo "Verify with: $0 --check $START $END"
echo "Then drive a turn and check the collector counters:"
echo "  otelcol_receiver_accepted_spans / otelcol_exporter_sent_spans"
