#!/usr/bin/env bash
# fix-maas-key-attribution.sh — make key_name / key_id populate in MaaS usage logs.
#
# THE BUG
#   With usageLogging enabled, the MaaS controller generates the EnvoyFilter
#   maas-model-access-logs. It reads three fields from Kuadrant filter state:
#
#       key_id          %FILTER_STATE(wasm.kuadrant.auth.identity.keyId:PLAIN)%
#       key_name        %FILTER_STATE(wasm.kuadrant.auth.identity.keyName:PLAIN)%
#       organization_id %FILTER_STATE(wasm.kuadrant.auth.identity.organizationId:PLAIN)%
#
#   None of them resolve. Measured on rosa-wv5l4 2026-11-27: not just the
#   nested paths but the WHOLE blob is unreadable — a probe emitting
#   %FILTER_STATE(wasm.kuadrant.auth.identity:PLAIN)% logged "-", and so did
#   all six DYNAMIC_METADATA spellings (envoy.filters.http.ext_authz[:identity],
#   kuadrant.auth.identity[:keyName], wasm.kuadrant.auth.identity[:keyName]).
#   The AuthPolicy's response.success.filters.identity does export keyId and
#   keyName, but that data never reaches the access logger.
#
#   Meanwhile user_id / subscription / groups DO populate, because they travel
#   a different route: AuthPolicy response.success.HEADERS -> X-MaaS-* request
#   headers -> the EnvoyFilter's header_to_metadata filter -> access log CEL.
#
# THE FIX
#   Send the key fields down that same proven path.
#     1. AuthPolicy: add X-MaaS-Key-Name and X-MaaS-Key-Id, sourced from
#        auth.metadata.apiKeyValidation.{keyName,keyId} — the same metadata
#        step X-MaaS-Username already uses, and confirmed present: a direct
#        POST to /internal/v1/api-keys/validate returns keyId and keyName.
#     2. EnvoyFilter: add header_to_metadata rules for those two headers and
#        rewrite the key_name / key_id access-log attributes to read the
#        metadata, identical in shape to the working user_id attribute.
#
#   organization_id is NOT fixed: the AuthPolicy exports no organizationId at
#   all, so there is no source for it on this cluster. It stays "-". No
#   dashboard references it.
#
# WHY IT IS A SCRIPT AND NOT A YAML
#   Both objects are generated and owned by the MaaS controller
#   (app.kubernetes.io/managed-by=maas-controller; the EnvoyFilter also carries
#   an ownerReference to maas.opendatahub.io/v1alpha1 Config/default). They
#   cannot be declaratively owned by us, so the fix is an idempotent re-patch
#   that must be re-run after anything that makes the controller regenerate
#   them (operator upgrade, toggling usageLogging, Config edits).
#
# Usage:
#   ./fix-maas-key-attribution.sh            # apply + verify
#   ./fix-maas-key-attribution.sh --check    # report only, change nothing
set -uo pipefail

GW_NS=openshift-ingress
AP=maas-gateway-auth
EF=maas-model-access-logs
MODE=apply
case "${1:-}" in
  --check) MODE=check ;;
  "")      ;;
  *) echo "Unknown flag: $1" >&2; exit 1 ;;
esac

G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[0;33m'; Z=$'\033[0m'
ok(){ echo "  ${G}✓${Z} $*"; }; bad(){ echo "  ${R}✗${Z} $*"; }; warn(){ echo "  ${Y}!${Z} $*"; }

oc whoami >/dev/null 2>&1 || { bad "not logged in"; exit 1; }
oc get authpolicy "$AP" -n "$GW_NS" >/dev/null 2>&1 || { bad "AuthPolicy $AP not found"; exit 1; }
oc get envoyfilter "$EF" -n "$GW_NS" >/dev/null 2>&1 \
  || { bad "EnvoyFilter $EF not found — is usageLogging enabled?"; exit 1; }

have_ap(){ oc get authpolicy "$AP" -n "$GW_NS" -o json 2>/dev/null | grep -qc 'X-MaaS-Key-Name'; }
have_ef(){ oc get envoyfilter "$EF" -n "$GW_NS" -o json 2>/dev/null | grep -qc 'x-maas-key-name'; }

echo "── MaaS key attribution ────────────────────────────"
if [[ "$MODE" == check ]]; then
  have_ap && ok "AuthPolicy has X-MaaS-Key-Name/Id" || bad "AuthPolicy missing key headers"
  have_ef && ok "EnvoyFilter reads key_name/key_id from headers" || bad "EnvoyFilter still on FILTER_STATE"
  exit 0
fi

# ── 1. AuthPolicy ───────────────────────────────────────────────────────
PATCH=$(cat <<'EOF'
{"spec":{"defaults":{"rules":{"response":{"success":{"headers":{
  "X-MaaS-Key-Name":{"metrics":false,"priority":0,
    "plain":{"selector":"auth.metadata.apiKeyValidation.keyName"},
    "when":[{"predicate":"request.headers.authorization.matches(\"^Bearer sk-oai-.*\")"}]},
  "X-MaaS-Key-Id":{"metrics":false,"priority":0,
    "plain":{"selector":"auth.metadata.apiKeyValidation.keyId"},
    "when":[{"predicate":"request.headers.authorization.matches(\"^Bearer sk-oai-.*\")"}]}
}}}}}}}
EOF
)
if oc patch authpolicy "$AP" -n "$GW_NS" --type merge -p "$PATCH" >/dev/null 2>&1; then
  ok "AuthPolicy: X-MaaS-Key-Name / X-MaaS-Key-Id present"
else
  bad "AuthPolicy patch failed"; exit 1
fi

# ── 2. EnvoyFilter ──────────────────────────────────────────────────────
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
for attempt in 1 2 3; do
  oc get envoyfilter "$EF" -n "$GW_NS" -o json > "$TMP/ef.json" 2>/dev/null
  python3 -I - "$TMP/ef.json" <<'PYEOF'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
NEW=[("X-MaaS-Key-Name","key_name"),("X-MaaS-Key-Id","key_id")]
CEL=('%CEL("envoy.filters.http.header_to_metadata" in metadata.filter_metadata '
     '? metadata.filter_metadata["envoy.filters.http.header_to_metadata"]["{k}"] '
     ': request.headers["{h}"])%')
for cp in d['spec'].get('configPatches',[]):
    tc=cp.get('patch',{}).get('value',{}).get('typed_config',{})
    if not isinstance(tc,dict): continue
    if 'header_to_metadata' in str(tc.get('@type','')):
        rules=tc.setdefault('request_rules',[])
        have={r.get('header') for r in rules}
        for hdr,key in NEW:
            if hdr not in have:
                rules.append({"header":hdr,"on_header_present":{
                    "key":key,"metadata_namespace":"envoy.filters.http.header_to_metadata",
                    "type":"STRING"}})
    for al in tc.get('access_log',[]):
        attrs=al.get('typed_config',{}).get('attributes',{}).get('values')
        if attrs is None: continue
        for a in attrs:
            if a.get('key')=='key_name':
                a['value']={"string_value":CEL.format(k="key_name",h="x-maas-key-name")}
            elif a.get('key')=='key_id':
                a['value']={"string_value":CEL.format(k="key_id",h="x-maas-key-id")}
json.dump(d,open(p,'w'))
PYEOF
  if oc replace -f "$TMP/ef.json" >/dev/null 2>&1; then
    ok "EnvoyFilter: key_name / key_id now read from X-MaaS-* headers"
    break
  fi
  # `oc replace` loses to the controller's own writes; refetch and retry.
  [[ $attempt == 3 ]] && { bad "EnvoyFilter replace failed after 3 attempts"; exit 1; }
  warn "EnvoyFilter changed under us — refetching (attempt $((attempt+1))/3)"
  sleep 3
done

warn "organization_id stays \"-\": the AuthPolicy exports no organizationId"
echo "  Re-run this after any operator upgrade or usageLogging toggle."
