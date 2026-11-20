# Handoff: where the scripts path got to, and where GitOps still differs

Written 2026-11-19 from the scripts side, working on `rosa-wv5l4`. Everything
below is measured on a live 100-seat cluster, not inferred. The scripts branch
is `feat/loki-odf-object-storage` (draft PR #6), which is the base this branch
sits on — it gained 8 commits today, so **rebase before trusting the base**.

## 1. One of your uncommitted fixes is now committed upstream

`deploy-rhoai-observability.sh` had `[[ test ]] && break` in two polling loops.
Under `set -euo pipefail` that returns 1 when the test fails and kills the
script, so both loops aborted on their first poll. It was sitting uncommitted
in the sibling worktree; I committed it as **`434190b`** with the `sv68v`
context from the comment. If that was your fix, it is upstream now — drop your
local copy on rebase rather than resolving a conflict.

## 2. Dashboard flags: GitOps sets 4, scripts now set 7

`values.yaml` here lists `mcpCatalog`, `mcpRegistry`, `genAiStudio`,
`observabilityDashboard`. The scripts path (`enable-dashboard-features.sh`,
commit `03f1313`) sets those plus three more:

| flag | what breaks without it |
|---|---|
| `externalModels` | the External models page. The MaaS model is `Ready` and **invisible** — this is what made us think the model had not deployed. |
| `modelAsService` | the Models-as-a-Service pages. |
| `promptManagement` | the prompt registry. **See the caveat below before enabling.** |

**Do not enable `promptManagement` in GitOps until an MLflow CR is modelled.**
The flag only reveals the page; the page needs a backend. With
`mlflowoperator: Managed` you get the operator and an `mlflow-ui` pod but **no
CR**, and nothing creates one. Save prompt then fails with *Service
Unavailable*, and the only clue is `deploy/mlflow-ui` logging every 30s:

```
MLflow CR auto-discovery failed, MLflow endpoints will return 503
MLflow endpoint called but MLflow is not configured  uri="/api/v1/prompts?workspace=agentic-user1"
```

Enabling the flag without the CR exposes a broken page rather than a working
one. The scripts equivalent is `deploy-rhoai-mlflow.sh` (commit `7bcd24a`); its
two manifests in `operator-patches/` are a reasonable model for a chart. Three
constraints that are not negotiable: the CR **must be named literally
`mlflow`**, it must use `backendStoreUriFrom` (never inline `backendStoreUri`),
and the backend URI **must end `?sslmode=disable`** because the operator
requires SSL and the stock postgresql image does not serve it. Give it its own
PostgreSQL — the standalone MLflow in the `mlflow` namespace is the OTLP trace
backend for the whole demo and must not be disturbed. RHOAI MLflow has no OTLP
ingestion, so the split is permanent: prompts here, traces there.

Your existing note that `observabilityDashboard` is necessary-but-not-sufficient
is correct and generalises — most of these flags gate a page whose backend is a
separate concern.

## 3. Observability has three prerequisite operators, and the DSCI lies

`monitoring.managementState: Managed` with an empty `metrics:` reports
`MonitoringReady=True` and provisions **nothing** — the namespace exists with
zero pods. The honest condition is `MonitoringStackAvailable`
(`False/MetricsNotConfigured`). Per RHOAI 3.5 docs the stack needs **Cluster
Observability Operator, Tempo, and Red Hat build of OpenTelemetry**; a stock
ROSA cluster ships only the first. Setting `metrics` without the other two puts
the DSCI into `Ready=False/MissingOperator`, which has visible collateral — it
is what made the `models-as-a-service` project disappear from the dashboard.

After installing the operators the **rhods-operator must be restarted**; it
caches API discovery and will not see the new CRDs otherwise.

**The Perses trap, which will bite GitOps identically.** RHOAI creates a
NetworkPolicy `perses-operator-access` in `redhat-ods-monitoring` admitting
port 8080 only from namespace `openshift-cluster-observability-operator`. If
COO was installed cluster-wide the operator is in `openshift-operators`, that
namespace does not exist, and the policy can never match. Perses then serves
200s with **zero projects and zero dashboards** and the console says *"No
dashboards were found. Verify that the monitoring stack is configured
correctly"* — pointing you at a stack where everything is green. Resolve the
namespace dynamically:

```
oc get pods -A -l app.kubernetes.io/name=perses-operator
```

Also: **Perses CRs that failed before Perses existed are never retried.** They
sit at `PersesBackendError` forever and must be annotated to re-reconcile —
and that includes the **PersesDatasource** objects, not just the dashboards.
Miss the datasources and every panel renders *"No datasource found for
'data-science-prometheus-datasource'"*. Finally the `rhods-dashboard` pod
registers its `/perses` proxy at boot, so a pod older than the Perses instance
serves `index.html` for `/perses/*` and the browser reports
`Unexpected token '<', "<!doctype "... is not valid JSON`.

## 4. Seat identities do not exist, and `oc` cannot create them on HCP

The demo never had per-seat users: two identities and an empty `oauth/cluster`.
`0-admin-setup.sh` has always bound `claw-user` to an `agentic-user<N>` that
did not exist.

**On ROSA HCP `oauth/cluster` is immutable from the guest cluster** — a
ValidatingAdmissionPolicy rejects writes and tells you to modify the
HostedCluster. IdPs must be created with `rosa` from the bastion. Detect with
`oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}'`
→ `External`. Creating an htpasswd Secret in `openshift-config` does nothing
there. If GitOps is meant to be one-shot and declarative, **the IdP cannot be
part of it on HCP** — it has to come from the AgnosticV/ansible layer.

Everything else is in-cluster and GitOps-able: `admin` on the seat's own
namespace, `claw-user`, and **`opendatahub.io/dashboard=true`** on the
namespace, which is the label that lists a seat as an AI project. No seat had
that label.

**Heads up:** `rosa create idp` reconfigures the OAuth stack and redeployed the
oauth server, which invalidated my existing `oc` token mid-session. Expect to
re-login after creating it.

## 5. MaaS per-user attribution needs the key minted *as* the seat

The `user` dimension in `authorized_hits_total` records **who minted the key**,
not who called. Minted the default way every key belongs to whoever ran the
script, so all 100 seats collapse into `user="cluster-admin"`. `captureUser:
true` does not help; it is an identity problem. Proven fix:
`maas-mint-seat-keys.sh --as-seat` logs in as each seat and mints as that seat
— measured, a key minted as `agentic-user1` reports `user="agentic-user1"`.

For GitOps this means key minting cannot be a single admin-run Job if you want
per-user numbers; it needs each seat's credentials.

## 6. Things that will waste your time if nobody tells you

- **Do not run `demo-preflight.sh` during a rollout.** Mid-rollout it reported
  `20/1898` failures; every one was transient and all flagged seats passed
  19/19 on retest. The tell is the *check total* moving between runs
  (1900 → 1898 → 1755 → 1862) — that means checks erroring, not failing.
  On macOS use `PREFLIGHT_MAX_PARALLEL=4`.
- **`HTTP 000` is the macOS resolver, not the cluster.** Same for
  `ssh: Could not resolve hostname` on the bastion while `dig` answers fine.
  `sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder`.
- **Preflight's "could not resolve the OpenShift apps domain" is an AUTH
  error**, not DNS. It queries the cluster for the domain.
- **The model is not slow.** Measured on the RHDP endpoint: ~68 tok/s decode,
  **no degradation from 1 to 20 concurrent requests**, tiny-prompt round trip
  0.8s. An agent turn is two LLM calls at ~27k context. No RHDP ticket needed.
  Do not count SSE frames and call them tokens — that made decode look like
  6.5 tok/s when it is ~68.

## Current state of rosa-wv5l4

100 seats at 19/19 preflight, 1102 pods Running, 100 Claws Ready, per-seat MaaS
keys with working per-user attribution, Gen AI Playground and prompt registry
working, full observability stack (11 pods, 7 dashboards, 4 datasources).
