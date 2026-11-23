# Demo links — `s4p7f`

Cluster `ocp.s4p7f.sandbox3434.opentlc.com`, ordered from demo.redhat.com
as Field Sourced Content CI against branch `feat/gitops-openclaw-demo`.
30 seats, model `qwen3-235b-a22b`.

Regenerate this for another cluster with `../demo-urls.sh --site ocp`, or
by reading the routes directly — every link below is
`oc get route -A`, not something written by hand.

## For attendees

Each seat has its own URL. The `f881d` code is derived from the cluster
GUID, so it is stable for the life of the cluster but differs between
clusters.

```
https://claw-f881d-user<N>.apps.ocp.s4p7f.sandbox3434.opentlc.com     N = 1..30
```

Seat 1, as an example:
<https://claw-f881d-user1.apps.ocp.s4p7f.sandbox3434.opentlc.com>

**Login:** `agentic-user<N>` via the **htpasswd** button on the login
page — NOT the Keycloak/`rhbk` one, which is RHDP's own `user<N>` set and
is not bound to any seat.

One shared password for every seat:

```bash
oc get secret seat-identities-password -n models-as-a-service \
  -o jsonpath='{.data.password}' | base64 -d
```

It means any attendee can log in as any other seat. Right for a workshop
where it goes on a slide; rotate or tear the cluster down afterwards.

## Presenter and platform

| What | URL |
|---|---|
| OpenShift console | <https://console-openshift-console.apps.ocp.s4p7f.sandbox3434.opentlc.com> |
| RHOAI dashboard | <https://rhods-dashboard-redhat-ods-applications.apps.ocp.s4p7f.sandbox3434.opentlc.com> |
| MaaS gateway | <https://maas.apps.ocp.s4p7f.sandbox3434.opentlc.com> |
| ArgoCD | <https://openshift-gitops-server-openshift-gitops.apps.ocp.s4p7f.sandbox3434.opentlc.com> |
| Keycloak (RHDP users) | <https://sso.apps.ocp.s4p7f.sandbox3434.opentlc.com> |
| Model catalog | <https://model-catalog.apps.ocp.s4p7f.sandbox3434.opentlc.com> |
| Data science gateway | <https://data-science-gateway.apps.ocp.s4p7f.sandbox3434.opentlc.com> |

Admin login for the console: `admin`, password from the RHDP order page.

### Observability

| What | URL |
|---|---|
| Loki (logs) | <https://logging-loki-openshift-logging.apps.ocp.s4p7f.sandbox3434.opentlc.com> |
| RHOAI Prometheus | <https://data-science-prometheus-route-redhat-ods-monitoring.apps.ocp.s4p7f.sandbox3434.opentlc.com> |
| RHOAI Thanos | <https://data-science-thanos-querier-route-redhat-ods-monitoring.apps.ocp.s4p7f.sandbox3434.opentlc.com> |
| Cluster Thanos | <https://thanos-querier-openshift-monitoring.apps.ocp.s4p7f.sandbox3434.opentlc.com> |
| NooBaa (object store) | <https://noobaa-mgmt-openshift-storage.apps.ocp.s4p7f.sandbox3434.opentlc.com> |

The RHOAI **Observe & monitor** section lives inside the dashboard rather
than on its own route.

### Pipelines

| What | URL |
|---|---|
| Tekton results API | <https://tekton-results-api-openshift-pipelines.apps.ocp.s4p7f.sandbox3434.opentlc.com> |

The broker image build is a PipelineRun in `session-broker`; watch it in
the console under Pipelines, or:

```bash
oc get pipelinerun -n session-broker
```

## Per-seat backends

Each seat namespace `agentic-user<N>` also exposes, mostly for debugging
rather than for attendees:

```
instance-agentic-user<N>...                 the same Control UI as the audience route
fantaco-customer-service-agentic-user<N>... REST backends
fantaco-product-service-agentic-user<N>...
fantaco-sales-order-service-agentic-user<N>...
mcp-customer-route-agentic-user<N>...       MCP servers (a GET returns 406; that means UP)
mcp-product-route-agentic-user<N>...
mcp-sales-order-route-agentic-user<N>...
```

Prefer `instance-…` over the audience URL when testing before an event:
hitting the audience URL assigns a seat once the broker is in play.

## Not yet live

- **Session broker** — the image builds (`session-broker:latest` is in
  the internal registry), but the Deployment is blocked behind the
  CloudNativePG CRD. Once up it adds a route in `session-broker` and a
  status page whose URL is printed by `../update-broker-ocp.sh
  --rotate-status-key`, not discoverable from the cluster.
- **Standalone MLflow route** — the trace backend is deployed but not
  exposed; reach it in-cluster at
  `http://mlflow.mlflow.svc.cluster.local:5000`.

## Checking it is actually working

```bash
# every seat has a key and a ready agent
oc get claw -A -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | sort | uniq -c
oc get secret -A | grep -c litellm-api-key

# inference really works, as a seat rather than as admin
K=$(oc get secret litellm-api-key -n agentic-user1 -o jsonpath='{.data.api-key}' | base64 -d)
curl -sk https://maas.apps.ocp.s4p7f.sandbox3434.opentlc.com/v1/chat/completions \
  -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-235b-a22b","messages":[{"role":"user","content":"say ready"}],"max_tokens":8}'
```

**After any cluster stop/start, two things need a kick** before anything
works, and both present as everything looking healthy:

```bash
oc get pods -n openshift-gitops          # controller comes back 0/1; delete the pod
oc rollout restart deploy/maas-default-gateway-openshift-default -n openshift-ingress
oc rollout restart deploy/authorino -n kuadrant-system
```

The second one matters most: the gateway serves 503 for everything —
inference included — with every CR reading Ready and the Gateway
reporting `Programmed`.
