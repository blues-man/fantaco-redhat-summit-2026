# Handoff: findings from the GitOps side that affect the scripts

Reply to [`HANDOFF-scripts-parity.md`](HANDOFF-scripts-parity.md). Written
2026-11-19/20 on `sv68v`, a **self-managed OCP-on-AWS (IPI) sandbox** ordered
through Field Sourced Content CI — not ROSA. Several differences below come
from that, and they are the ones most likely to bite you on a non-ROSA
cluster. Everything is measured, not inferred.

Your two fixes to `deploy-rhoai-observability.sh` both landed: `434190b` has
the `set -e` loop fix AND the `cluster-observability-operator` addition to the
install list and wait loop. Nothing outstanding there.

## 1. `demo-flow-test.sh` is giving you false failures RIGHT NOW

This is the one to act on, and it is independent of GitOps — it will
misreport on `rosa-wv5l4` exactly as it did here.

Six of seventeen steps failed while the demo was working throughout. Every
one was the parser. The gateway no longer prints a single JSON object:

```
{"transport":"sse"}                            <- preamble
{"payloads":[{"text":...}],"meta":{...}}       <- the reply
[agent] run <uuid> ended with stopReason=stop  <- trailing log
```

`sed -n '/{/,$p'` yields two objects plus a log line, `json.load` raises,
`extract_reply` swallows the error and returns `""`, and every
`assert_contains` fails against an empty string. The symptom is `Full reply:`
followed by nothing — which reads as the agent answering nothing, while the
same run reports `stopReason=stop` with 6 successful MCP tool calls.

The reply shape also moved: it is **top-level `payloads[0].text`** now, which
`extract_reply` did not know about.

Fixed on this branch (`send_message` scans for complete JSON objects and keeps
the last one carrying a reply; `extract_reply` gains the current path while
keeping the two older ones). **Cherry-pick it** — it is a standalone commit
touching only that file. Step 3 went from "Missing: customer name" with an
empty reply to passing; the suite went 11/17 → 12/15 with the remaining
failures being repeat-run skill pollution, which `--cleanup` clears.

## 2. Install COO in its own namespace and the Perses trap stops existing

You describe patching `perses-operator-access`, whose NetworkPolicy admits
port 8080 only from `openshift-cluster-observability-operator`, after COO is
installed cluster-wide. There is a better fix: **install COO into that
namespace in the first place.**

```yaml
Namespace      openshift-cluster-observability-operator
OperatorGroup  (same ns, upgradeStrategy: Default)
Subscription   cluster-observability-operator  (same ns)
```

Two things resolve at once:

- The NetworkPolicy matches by construction. Confirmed on `sv68v` — its
  selector is `namespaceSelector: kubernetes.io/metadata.name=openshift-cluster-observability-operator`
  plus `podSelector: app.kubernetes.io/name=perses-operator`, and COO now
  satisfies both. No patch, nothing to re-apply after an operator upgrade.
- **RHOAI's monitoring precondition is satisfied.** This is the part that cost
  me the most time: with COO installed cluster-wide into `openshift-operators`
  the DSCI kept reporting

  ```
  Ready=False MissingOperator
  "ClusterObservability operator must be installed for metrics configuration"
  ```

  with the CSV `Succeeded`, every CRD registered (`monitoringstacks.monitoring.rhobs`,
  `perses.perses.dev`, `uiplugins.observability.openshift.io`) and
  `observability-operator`, `perses-operator` and `obo-prometheus-operator`
  all Running. Restarting `rhods-operator` did not clear it — the check is not
  discovery-based. Reinstalling into the dedicated namespace cleared it within
  one reconcile.

So the namespace is not cosmetic, and `deploy-rhoai-observability.sh` installs
COO into `openshift-operators` today. Worth changing on your side too.

**It also needs TWO `rhods-operator` restarts.** The first naturally fires
when the CSV reports `Succeeded` — which is before `observability-operator`
and `perses-operator` are actually Running, so discovery is re-cached empty.
Wait for the operator **pods**, not the CSV phase.

Final state here: `MonitoringStackAvailable`, `TempoAvailable`,
`OpenTelemetryCollectorAvailable`, `PersesAvailable` all True, DSCI
`Ready=True`, 11 pods in `redhat-ods-monitoring` — matching your rosa-wv5l4
numbers.

## 3. `promptManagement` is safe when something models the MLflow CR

Your "do not enable this" is right for the scripts path and wrong as a general
rule, so it is worth splitting the two.

The flag reveals a page; the page needs a CR; on the scripts path nothing
creates one, so you get *Service Unavailable* and `mlflow-ui` logging
`MLflow CR auto-discovery failed` every 30s. Correct.

The GitOps chart models the CR — `components/observability/templates/mlflow-rhoai.yaml`,
honouring all three of your constraints (named literally `mlflow`,
`backendStoreUriFrom`, URI ending `?sslmode=disable`) with its own PostgreSQL
so the standalone OTLP trace server is untouched. Verified on `sv68v`:
`MLflowOperatorReady=True`, `Available=True`, `Migration=True`.

So the flag is enabled here, with a note in `values.yaml` that it must be
dropped if `observability.mlflowRhoai` is ever set false. `deploy-rhoai-mlflow.sh`
is the scripts-side equivalent; once that runs as standard, the flag is safe
for you too.

## 4. Smaller things

- **Perses CR conditions are `Available`/`Degraded`, not `Accepted`/`Ready`.**
  I briefly read 12 healthy CRs as 12 broken ones by checking for the wrong
  condition types. If you script a Perses health check, select on `Available`.
- **Your `HTTP 000` note is confirmed from a second direction.** The audience
  Route returned `000` from my Mac and **200 from inside the cluster** for the
  same URL, with DNS resolving and the Route `Admitted=True`. Treating a `000`
  as a cluster fault would have sent me chasing the Route.
- **`deploy-mcp-catalog.sh --check` reports the Kuadrant broker as three
  failures on a GitOps cluster, and that is expected** — the chart implements
  only mechanism 1 (the `gen-ai-aa-mcp-servers` ConfigMap), because mechanism 2
  does not feed the dashboard catalog. Not a parity gap.
- **`mcpRegistry`'s gate is `requiredComponents: [MLFLOW]`**, not
  MODEL_REGISTRY as the earlier note implied. `mcpCatalog` is the one gated on
  MODEL_REGISTRY.

## 5. Where GitOps still differs from scripts

Not claims of parity — the honest list of what this branch does not do.

| | |
|---|---|
| per-seat MaaS keys | not minted by the chart; keys cannot exist before the chain is Ready. Your `--as-seat` finding means this cannot become a single admin-run Job if per-user attribution is wanted. |
| skills / plugins | still `6-inject-enterprise-skills.sh`; copying into a running pod is not declarative. |
| heartbeat | a file inside the PVC, inverted (missing file ARMS it). Not a cluster resource. |
| broker | manifests sync, but the image is built in-cluster and the audience code is runtime state. Off by default. |
| htpasswd IdP | modelled as an opt-in component, and it detects `controlPlaneTopology=External` and exits cleanly, per your HCP note. Untested on HCP. |
| Kuadrant MCP broker | deliberately not modelled, see above. |

## Current state of sv68v

1 seat (pinned deliberately for a first run; the order was 30 users), 14 Argo
Applications Synced+Healthy, preflight 19/19 bar the macOS `HTTP 000`, MaaS
smoke test minting and inferring 200, Claw Ready, 11 seat pods, full RHOAI
observability stack, Gen AI studio and both projects visible.

---

# Addendum, 2026-11-24: the `main` agent is now declared in the CR

Re your `fix-agent-workspace-skills.sh` and the repatch block that re-adds
`main` after a re-seed.

**On a GitOps-deployed cluster neither is needed, and the fix cannot be
undone by a reset.** `agents.list` is Tier 3 / user-only in the operator's
own merge model (ADR-0013): the operator never touches it, and
`spec.config.raw` is merged into `operator.json`, which wins over PVC state.
So the seat CR now carries both `default` and `main` with the workspace, and
every pod start reapplies it by construction rather than by someone
remembering to run a script. That closes the "breaks mid-event at the next
audience reset" risk directly rather than racing it.

Two details, both from your commits, that the chart encodes:

- **Both entries, not just `main`.** The array is replaced wholesale, not
  appended to, so declaring only `main` would drop `default`.
- `agents.defaults.workspace` is also set, and the chart now comments the
  constraint that it must match where `seat-runtime` writes the skills
  (`paths.home` + `/workspace`). If those drift, the injection succeeds into
  a directory no agent reads — the same hallucinated-path symptom with a
  different cause.

**Keep the repatch block anyway.** It is idempotent (`some(a.id === "main")`)
and it is the only thing covering clusters this branch did not deploy.

**Your false-negative finding changed a test, not just a doc.** I had no
skills assertion at all. Worth knowing that `skills check --agent main` is
not reachable from a hook the way the others are: it needs an `oc exec` into
each gateway, so it stays a preflight concern rather than something the
chart can assert at sync time.

Also now declarative, since the last note: each seat's
`diagnostics.otel` + `config.env` pointing at the shared collector, derived
from one place so it cannot name a Service that does not exist; and the
broker status key moved to a create-if-absent hook, because a templated
Secret meant selfHeal reverted `--rotate-status-key` with no event saying
why. `compare-options: IgnoreExtraneous` does not help there — "extraneous"
means live-only resources, not manifests you authored.
