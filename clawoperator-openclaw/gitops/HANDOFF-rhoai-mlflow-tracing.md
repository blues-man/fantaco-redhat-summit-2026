# Handoff: OpenClaw traces now go to RHOAI MLflow — model this in GitOps

Written 2026-11-23 from the scripts side, proven on `rosa-wv5l4`, RHOAI 3.5.3.
Third note in the series, after `HANDOFF-scripts-parity.md` and your
`HANDOFF-gitops-findings.md`.

**Decision taken:** the demo moves to the RHOAI-managed MLflow. The standalone
community MLflow in the `mlflow` namespace is to be retired once this is
confirmed at fleet scale. All 105 seats are being repointed now.

## 1. Retract the "no OTLP ingest" claim — it was wrong

My earlier handoff and `HANDOFF.md` both said RHOAI MLflow has no OTLP trace
endpoint and the native path was blocked. **That was a testing error.** I
probed the gateway host with its `/mlflow` prefix, which legitimately 404s.
Ingest is on the **MLflow Service**, and it works:

```
POST https://mlflow.redhat-ods-applications.svc:8443/v1/traces
  Authorization: Bearer <SA token>     # TLS: service-ca.crt
  X-MLflow-Workspace: <namespace>
  x-mlflow-experiment-id: <id>
```

Status codes form a ladder, each naming the next missing piece:
`404` HTML (wrong host) → `400 Workspace context is required` →
`403 PERMISSION_DENIED` (needs RBAC) → `422 missing x-mlflow-experiment-id` →
`400 no spans found` (empty body) → **`200`**.

Red Hat documents the pattern in `red-hat-data-services/agentic-starter-kits`,
`agents/openclaw/deployment/docs/mlflow-tracing.md`.

## 2. A collector is mandatory, and one is enough

**OpenClaw cannot authenticate to MLflow itself.** The gateway container runs
with `automountServiceAccountToken` off — no
`/var/run/secrets/kubernetes.io/serviceaccount/token`, no `service-ca.crt`.
Verified directly in the pod. No amount of OTLP env configuration fixes this.

The starter kit solves it with a per-pod sidecar. **Don't** — that is 105 pod
specs, and the Claw CR has no field for extra containers. One shared collector
works and only needs the seat's endpoint env var changed.

Do **not** reuse RHOAI's `data-science-collector`: it is owned by
`Monitoring/default-monitoring`, so the operator reconciles away any exporter
you add. It also only has `otlp/tempo` today, despite RHOAI shipping a
`data-science-collector-mlflow-trace-export` ClusterRole.

The working manifest is in the scripts branch at
`clawoperator-openclaw/operator-patches/openclaw-mlflow-trace-collector.yaml`.
Shape:

- `OpenTelemetryCollector` (deployment mode) in namespace `openclaw-tracing`
- `bearertokenauth` extension reading the pod SA token
- `otlphttp/mlflow` exporter to the Service, `tls.ca_file` = service-ca.crt
- static headers `X-MLflow-Workspace` and `x-mlflow-experiment-id`
- **`compression: none`** — gzip makes MLflow return HTTP 400

## 3. RBAC: the role already exists, prefixed

The starter kit tells you to create `mlflow-integration` because 3.3.1 lacks
it. On 3.5.3 it ships as **`mlflow-operator-mlflow-integration`**. Bind that to
the collector's ServiceAccount; do not create a duplicate.

## 4. The namespace needs TWO labels, for two different consumers

Easy to get half-right and then stare at an empty UI:

| label | who needs it |
| --- | --- |
| `mlflow.opendatahub.io/workspace=true` | MLflow — matches `workspaceLabelSelector`, or every call fails `Workspace '<ns>' not found` |
| `opendatahub.io/dashboard=true` | the dashboard **project selector** — without it the workspace is not selectable in the UI |

## 5. The NetworkPolicy trap — read this before you copy anything

Seat namespaces restrict egress. You need a policy allowing the seat to reach
the collector on 4318. **It must select the gateway (`app: claw`).**

I got this wrong twice and the evidence actively misleads:

- The gateway has `HTTP_PROXY=http://instance-proxy:8080` with `NO_PROXY`
  covering only localhost, and the proxy logs
  `blocked CONNECT to unknown domain … :4318`. Everything says "the proxy
  mediates this".
- It does not. **The OTLP exporter bypasses the proxy.** The proof was in
  front of me the whole time: the standalone MLflow has never been in the
  proxy allowlist and had been receiving traces for days.
- Probing with Node `fetch` inside the gateway is worthless here — `fetch`
  honours `HTTP_PROXY`, the exporter does not. Use the collector's own
  counters instead: `otelcol_receiver_accepted_spans` and
  `otelcol_exporter_sent_spans` on port 8888.

Also: editing `instance-proxy-config` is pointless — the Claw operator
reconciles it back, and the CR exposes no allowlist field.

## 6. Prompt previews work, but the v2 API hides them

`request_preview` / `response_preview` **are** populated — the preview7 image
patch carries over unchanged:

```
request_preview:  "How many customers are in the FantaCo database?"
response_preview: "I've retrieved the list of customers from the FantaCo database…"
```

But `GET /api/2.0/mlflow/traces` returns a reduced TraceInfo with **no preview
fields at all**, which looks exactly like a regression. Use the v3 search:

```
POST /mlflow/api/3.0/mlflow/traces/search
{"locations":[{"mlflow_experiment":{"experiment_id":"<id>"}}],"max_results":5}
```

In the UI the Request/Response columns are hidden by default — **Columns
(4/18)** and enable them.

## 7. What GitOps should model

Declarative and safe to own:

- the `openclaw-tracing` namespace with **both** labels
- the ServiceAccount + ClusterRoleBinding to `mlflow-operator-mlflow-integration`
- the `OpenTelemetryCollector` CR
- the per-seat egress NetworkPolicy (gateway selector)
- the seat's `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` pointing at the collector

Not declarative, needs a Job or a hook:

- **the MLflow experiment**. It must exist before traces arrive, and it is
  created through the **gateway** REST API
  (`/mlflow/api/2.0/mlflow/experiments/create` with `X-MLflow-Workspace`), not
  on the Service and not as a CR. Its ID then has to reach the collector
  config, so either pin the ID or template it after a create-if-absent Job.
  Experiment IDs are **per workspace** — "experiment 2" is meaningless without
  the workspace, which is also why both headers are required.

## 8. Retiring the standalone MLflow

Once fleet-wide traces are confirmed in RHOAI MLflow, `deploy-traces-mlflow.sh`
and the `mlflow` namespace can go. Two things to check first, because they are
the reasons it existed:

- the **preview7 patched image** must stay — it is what makes previews show
  prompts instead of trace IDs, independently of which MLflow receives them;
- the standalone one is the only backend `audience-reset.sh` knew about, so
  keep its fallback path until GitOps owns the collector everywhere.

Scripts side now prefers the collector automatically when
`svc/openclaw-mlflow-collector` exists in `openclaw-tracing`, and falls back to
the standalone otherwise — so a cluster without the collector behaves as before.
