#!/usr/bin/env bash
# repair-langfuse-plugin.sh — Fix gateways wedged by a half-copied langfuse-tracer
#
# The failure this repairs looks like this in the gateway log:
#
#   Gateway failed to start: Invalid config at /home/node/.openclaw/openclaw.json:
#   plugins: plugin: plugin manifest not found:
#   /home/node/.openclaw/extensions/langfuse-tracer/openclaw.plugin.json
#
# Cause: audience-reset.sh copies the plugin with two `oc cp` calls. When the
# second one fails the directory is left holding index.js and nothing else, and
# the repatch (which used to test only for index.js) then writes a config that
# enables a plugin the gateway cannot load. The gateway refuses to boot, so the
# obvious fix — `oc exec` the missing file in — is unavailable: there is no
# running container to exec into.
#
# Two further obstacles shape the approach:
#
#   * `oc scale deployment/instance --replicas=0` does not stick. The operator
#     reconciles it back to 1 within ~20s, so there is no window in which the
#     PVC is free.
#   * instance-home-pvc is ReadWriteOnce, so a second pod can only mount it if
#     it lands on the same node as the crashlooping one.
#
# Hence: a repair pod pinned with nodeName to the instance pod's node, mounting
# the same PVC at /work (subPath `home`, matching the gateway's own mount). It
# writes the missing files, is deleted, and the deployment is restarted.
#
# Usage:
#   ./repair-langfuse-plugin.sh 1 50        # scan the range, repair what is broken
#   ./repair-langfuse-plugin.sh 30          # one user
#   ./repair-langfuse-plugin.sh --check 1 50  # report only, change nothing
#
# Healthy namespaces are skipped, so the whole range is safe to pass.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE_PREFIX="${NAMESPACE_PREFIX:-agentic-user}"
PLUGIN_SRC="${SCRIPT_DIR}/../claw_plugins/langfuse-tracer"
PLUGIN_SUBPATH="extensions/langfuse-tracer"
REPAIR_POD="plugin-repair"
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:2026.6.35-slim}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

CHECK_ONLY=false
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check|-n) CHECK_ONLY=true; shift ;;
    -h|--help)  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo -e "${RED}Unknown option: $1${RESET}" >&2; exit 1 ;;
    *)  POSITIONAL_ARGS+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL_ARGS[@]+"${POSITIONAL_ARGS[@]}"}"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 [--check] <start> [end]" >&2
  exit 1
fi
START="$1"; END="${2:-$1}"

for f in index.js openclaw.plugin.json; do
  if [[ ! -s "${PLUGIN_SRC}/${f}" ]]; then
    echo -e "${RED}ERROR: plugin source missing: ${PLUGIN_SRC}/${f}${RESET}" >&2
    exit 1
  fi
done

oc whoami &>/dev/null || { echo -e "${RED}ERROR: not logged in to OpenShift.${RESET}" >&2; exit 1; }

echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  langfuse-tracer plugin repair${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo -e "  Namespaces: ${NAMESPACE_PREFIX}${START}..${END}"
echo -e "  Source:     ${DIM}${PLUGIN_SRC}${RESET}"
$CHECK_ONLY && echo -e "  Mode:       ${YELLOW}--check (read-only)${RESET}"
echo ""

N_OK=0; N_FIXED=0; N_FAILED=0; N_SKIPPED=0
FAILED_NS=()

cleanup_repair_pod() {
  local ns="$1"
  oc delete pod "$REPAIR_POD" -n "$ns" --ignore-not-found --wait=false &>/dev/null || true
}

# Write the plugin into a PVC that no running gateway can reach.
repair_via_pod() {
  local ns="$1" node="$2"

  # A leftover pod from an interrupted earlier run would be Completed or
  # Terminating and unusable; start from a known state.
  oc delete pod "$REPAIR_POD" -n "$ns" --ignore-not-found --wait=true &>/dev/null || true

  # The namespace ResourceQuota (namespace-quota) rejects any container without
  # all four of requests.cpu/memory and limits.cpu/memory.
  oc apply -n "$ns" -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${REPAIR_POD}
  labels:
    app.kubernetes.io/name: plugin-repair
spec:
  nodeName: ${node}
  restartPolicy: Never
  containers:
  - name: repair
    image: ${OPENCLAW_IMAGE}
    command: ["sleep", "600"]
    resources:
      requests: {cpu: 10m, memory: 32Mi}
      limits:   {cpu: 100m, memory: 128Mi}
    volumeMounts:
    - name: claw-home
      mountPath: /work
      subPath: home
  volumes:
  - name: claw-home
    persistentVolumeClaim:
      claimName: instance-home-pvc
EOF

  if ! oc wait --for=condition=Ready "pod/${REPAIR_POD}" -n "$ns" --timeout=120s &>/dev/null; then
    echo -e "    ${RED}✗ repair pod never became Ready${RESET}"
    oc get pod "$REPAIR_POD" -n "$ns" -o jsonpath='{.status.conditions[*].message}' 2>/dev/null | head -c 300
    echo ""
    cleanup_repair_pod "$ns"
    return 1
  fi

  oc exec "$REPAIR_POD" -n "$ns" -- mkdir -p "/work/${PLUGIN_SUBPATH}" >/dev/null 2>&1 || true
  for f in index.js openclaw.plugin.json; do
    # `oc cp` prints tar warnings on a successful copy; the verify below is the
    # real test, so its exit code is not trusted either way.
    oc cp "${PLUGIN_SRC}/${f}" "${ns}/${REPAIR_POD}:/work/${PLUGIN_SUBPATH}/${f}" &>/dev/null || true
  done

  local verified=1
  if oc exec "$REPAIR_POD" -n "$ns" -- \
       sh -c "test -s '/work/${PLUGIN_SUBPATH}/index.js' && test -s '/work/${PLUGIN_SUBPATH}/openclaw.plugin.json'" &>/dev/null; then
    verified=0
  fi

  cleanup_repair_pod "$ns"
  return $verified
}

for i in $(seq "$START" "$END"); do
  NS="${NAMESPACE_PREFIX}${i}"

  if ! oc get ns "$NS" &>/dev/null; then
    N_SKIPPED=$((N_SKIPPED + 1))
    continue
  fi
  if ! oc get deployment instance -n "$NS" &>/dev/null; then
    echo -e "  ${DIM}${NS}: no OpenClaw instance — skipping${RESET}"
    N_SKIPPED=$((N_SKIPPED + 1))
    continue
  fi

  READY=$(oc get deploy instance -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  READY="${READY:-0}"

  # A ready gateway either has both files or does not have the plugin enabled;
  # either way it is booting, and nothing here needs to touch it.
  if [[ "$READY" -ge 1 ]]; then
    N_OK=$((N_OK + 1))
    continue
  fi

  POD=$(oc get pods -n "$NS" -l claw.sandbox.redhat.com/instance=instance -l app=claw \
        --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
  if [[ -z "$POD" ]]; then
    echo -e "  ${YELLOW}⚠ ${NS}: deployment has no pod — skipping${RESET}"
    N_SKIPPED=$((N_SKIPPED + 1))
    continue
  fi

  # Only repair the failure this script understands. A gateway down for another
  # reason (image pull, OOM, bad model config) must not be papered over with a
  # plugin copy and a restart that hides the real error.
  LOG=$(oc logs "$POD" -n "$NS" -c gateway --tail=40 2>/dev/null || true)
  if [[ -z "$LOG" ]]; then
    LOG=$(oc logs "$POD" -n "$NS" -c gateway --tail=40 --previous 2>/dev/null || true)
  fi
  if [[ "$LOG" != *"plugin manifest not found"* && "$LOG" != *"langfuse-tracer"* ]]; then
    echo -e "  ${YELLOW}⚠ ${NS}: not ready, but not the langfuse manifest failure — leaving alone${RESET}"
    echo -e "    ${DIM}$(echo "$LOG" | tail -3 | tr '\n' ' ' | cut -c1-160)${RESET}"
    N_SKIPPED=$((N_SKIPPED + 1))
    continue
  fi

  # `oc get pods -o wide | awk` is not usable here: when STATUS is
  # CrashLoopBackOff the columns shift and the node comes back as "40s".
  NODE=$(oc get pod "$POD" -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
  if [[ -z "$NODE" ]]; then
    echo -e "  ${RED}✗ ${NS}: cannot determine node for ${POD}${RESET}"
    N_FAILED=$((N_FAILED + 1)); FAILED_NS+=("$NS")
    continue
  fi

  echo -e "  ${CYAN}${NS}${RESET}: langfuse manifest missing (node ${DIM}${NODE}${RESET})"
  if $CHECK_ONLY; then
    N_FAILED=$((N_FAILED + 1)); FAILED_NS+=("$NS")
    continue
  fi

  if repair_via_pod "$NS" "$NODE"; then
    oc rollout restart deployment/instance -n "$NS" >/dev/null 2>&1 || true
    echo -e "    ${GREEN}✓${RESET} plugin files written, gateway restarting"
    N_FIXED=$((N_FIXED + 1))
  else
    echo -e "    ${RED}✗${RESET} repair failed"
    N_FAILED=$((N_FAILED + 1)); FAILED_NS+=("$NS")
  fi
done

# ── Settle ────────────────────────────────────────────────────────────
if (( N_FIXED > 0 )) && ! $CHECK_ONLY; then
  echo ""
  echo -e "  ${DIM}waiting for restarted gateways to settle...${RESET}"
  sleep 90
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
if $CHECK_ONLY; then
  echo -e "  ${GREEN}${N_OK}${RESET} ready, ${YELLOW}${N_FAILED}${RESET} need repair, ${N_SKIPPED} skipped"
else
  echo -e "  ${GREEN}${N_OK}${RESET} already ready, ${GREEN}${N_FIXED}${RESET} repaired, ${RED}${N_FAILED}${RESET} failed, ${N_SKIPPED} skipped"
fi
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
if (( ${#FAILED_NS[@]} > 0 )); then
  echo -e "  ${YELLOW}${FAILED_NS[*]}${RESET}"
fi
echo ""

# Final census is worth more than the per-namespace tally above: a gateway can
# be restarted successfully and still fail to come back for an unrelated reason.
if ! $CHECK_ONLY; then
  echo -e "${BOLD}Fleet readiness:${RESET}"
  NOT_READY=()
  for i in $(seq "$START" "$END"); do
    NS="${NAMESPACE_PREFIX}${i}"
    oc get deployment instance -n "$NS" &>/dev/null || continue
    R=$(oc get deploy instance -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    [[ "${R:-0}" -ge 1 ]] || NOT_READY+=("$NS")
  done
  if (( ${#NOT_READY[@]} == 0 )); then
    echo -e "  ${GREEN}✓ all gateways in range are ready${RESET}"
  else
    echo -e "  ${YELLOW}⚠ still not ready: ${NOT_READY[*]}${RESET}"
  fi
fi
