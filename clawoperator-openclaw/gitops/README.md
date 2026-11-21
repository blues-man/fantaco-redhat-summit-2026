# OpenClaw on OpenShift — GitOps

The declarative form of [`QUICKSTART.md`](../QUICKSTART.md) Section A.
Two ways to run it:

**Ordered from demo.redhat.com** — order **Field Sourced Content CI**,
point it at this repo, and tick the LiteMaaS box. Nothing else.

| order form field | value |
|---|---|
| GitOps repo URL | `https://github.com/blues-man/fantaco-redhat-summit-2026.git` |
| Revision | the branch you want |
| Path | `clawoperator-openclaw/gitops` |
| **Enable LiteMaaS/MaaS API Keys** | **ticked** — this is the demo's upstream credential |
| Model | `qwen3-235b-a22b` |
| Duration | longer than the event |
| Number of users | becomes the seat count |

**Standalone**, against a cluster you built yourself:

```bash
oc apply -f bootstrap/root-application.yaml
```

> **Status: not yet synced on a cluster.** Every manifest is a
> translation of a script or an `operator-patches/` file that works, and
> the chart renders under a simulated RHDP injection, but the whole has
> not been through a real order. **Scripts carry Vienna.**

## How RHDP feeds the MaaS key

This is the part worth reading before changing any value names.

Ticking **Enable LiteMaaS/MaaS API Keys** runs
`rhpds.litellm_virtual_keys.ocp4_workload_litellm_virtual_keys`, which
mints a *virtual key* against RHDP's LiteLLM and writes
`litellm_api_base_url` and `litellm_virtual_key` into
`agnosticd_user_data`. The catalog item
(`agnosticv/agd_v2/ocp-field-asset-aws/common.yaml`) reads them back:

```yaml
ocp4_workload_field_content_litemaas_api_url: "{{ lookup('agnosticd_user_data', 'litellm_api_base_url', default='') }}"
ocp4_workload_field_content_litemaas_api_key: "{{ lookup('agnosticd_user_data', 'litellm_virtual_key', default='') }}"
```

and `roles/ocp4_workload_field_content` (in `rhpds/core_workloads`)
turns those into Helm values on the ArgoCD Application it creates:

```yaml
litemaas:
  enabled: true          # false, and only this key, if you did not tick the box
  apiUrl: https://litellm-prod.apps.maas.redhatworkshops.io
  apiKey: sk-…           # the virtual key
  model: qwen3-235b-a22b
deployer:
  domain: apps.cluster-….sandbox.opentlc.com
  apiUrl: https://api.cluster-….sandbox.opentlc.com:6443
gitops:
  repoURL: …             # what you typed in the order form
  revision: …
  path: …
multi_user:
  num_users: 5
  users: [{username: user1}, …]
guid: abcde
bases: {virt: false, rhoai: false, aap: false}
user: {count: 5}
```

**That virtual key *is* `MAAS_UPSTREAM_API_KEY`.** It is the one
credential the repo could never provide for itself, and the whole
MaaS-over-MaaS chain hangs off it: `templates/_helpers.tpl` maps
`litemaas.apiKey` to the upstream secret, strips the scheme off
`litemaas.apiUrl` (ExternalProvider wants a bare FQDN), and takes the
model from the dropdown.

Four consequences that are easy to get wrong:

- **`gitops.repoURL`, capital URL.** RHDP sets that key; a chart reading
  `gitops.repoUrl` silently keeps using whatever is hardcoded in
  `values.yaml`, so child Applications would ignore the branch you
  ordered. The helpers coalesce both.
- **`guid` is top-level**, not `deployer.guid`.
- **The key expires.** The duration dropdown is the lifetime of the
  demo's inference, not of a login. Pick longer than the event.
- **Do not tick the RHOAI base.** If you do, `bases.rhoai: true` and the
  chart skips its own Subscription — but it still applies the
  DataScienceCluster, because the generic base does not enable
  `aigateway`, `mlflowoperator`, `mcplifecycleoperator`,
  `modelregistry`, `ogx` or `trustyai`, and the demo needs all six.

If `litemaas.enabled` is false and no `maas.upstreamApiKey` is set, the
whole MaaS Application is **not rendered at all**. That is deliberate:
an empty key produces a chain that reaches Ready and fails only on the
first real inference, which is the single worst failure mode in this
stack. Better to have nothing than something that lies.

## What this is for

The scripts work, and they encode a lot of hard-won knowledge. What they
cannot do is tell you what the cluster is *supposed* to look like — that
only exists as the union of 40 shell scripts and the order you ran them
in. This expresses the same cluster as resources, so the intended state
is readable, diffable, and re-appliable.

The concrete wins, in order of how much they matter:

1. **A pod restart stops being an event that needs repairing.** Everything
   `1-deploy-claw.sh` and `post-restart-repatch.sh` poke into
   `openclaw.json` with `oc exec ... node -e` lives in `spec.config.raw`
   instead, which the operator merges *before* its enrichment pipeline
   runs. `post-restart-repatch.sh` has nothing left to undo.
2. **The MaaS label trap cannot happen.** The chart creates the upstream
   secret, so `inference.llm-d.ai/ipp-managed=true` is applied by
   construction rather than by remembering.
3. **The ROSA-STS NooBaa dance disappears.** The chart owns the NooBaa CR
   and its own BucketClass and StorageClass, so `manualDefaultBackingStore`
   is a field rather than a patch, and the bucket class it uses is never
   the rejected default one. Identical behaviour on self-managed
   OCP-on-AWS and on ROSA STS.
4. **Seat count is one number.** `seats.count: 100` replaces every
   `./script.sh 1 100`.

## Target cluster

A **self-managed OCP on AWS (IPI)**, sized for the seat count. ROSA HCP
also works; nothing here is ROSA-specific any more.

Pods are the binding constraint, not CPU or memory — measured at 11 pods,
0.57 CPU and 2.66 GiB per seat. At 100 seats a cluster sat at 71% of its
pod ceiling while using 46% of memory requests and 20% of CPU.

```
worker nodes = ceil((11 x N + 320) / 200)
```

`m6a.4xlarge` or `m7a.4xlarge`. The workload wants ~4.7 GiB per requested
core; general-purpose `m` gives 4 GiB/vCPU and matches, compute-optimised
`c` gives 2 and makes you buy twice the CPU to get the memory.

Two differences from the ROSA notes elsewhere in this repo, both in your
favour on IPI:

- Worker `MachineSet`s exist. Scale with `oc scale machineset`, not
  `rosa edit machinepool`.
- `maxPods` is settable via a `KubeletConfig`, so the 250-pods-per-node
  ceiling is not fixed. The formula above still assumes 200 per node for
  rollout headroom.

## Prerequisites

| | |
|---|---|
| `openshift-gitops` installed | its controller needs cluster-admin: this creates operators, CRDs and namespaces |
| Gateway API enabled | the MaaS gateway needs a `GatewayClass` on `openshift.io/gateway-controller/v1` |
| `maas.upstreamApiKey` | the RHDP virtual key. On RHDP it arrives from AgnosticV; standalone, pass it as a Helm parameter |
| `deployer.guid`, `deployer.domain` | also from AgnosticV. The GUID seeds deterministic database passwords; the domain derives the MaaS gateway hostname |

## Layout

```
gitops/
├── bootstrap/root-application.yaml   the one manual apply
├── values.yaml                       every knob, one file
├── templates/                        the Applications and ApplicationSets
└── components/
    ├── cluster-prereqs/   UWM, claw-user ClusterRole, per-seat RoleBindings
    ├── rhoai/             operator + DataScienceCluster
    ├── odf-mcg/           NooBaa, pv-pool store, own BucketClass/StorageClass
    ├── maas/              gateway, Postgres, Connectivity Link, model chain
    ├── observability/     LokiStack + OBC, both MLflows
    ├── mcp-catalog/       the gen-ai-aa-mcp-servers ConfigMap
    └── seat/              Claw CR, quota, NetworkPolicies, ServiceMonitor
```

The FantaCo backends are **not** copied here. The seat ApplicationSets
point at the existing `helm/fantaco-app` and `helm/fantaco-mcp` charts in
this repository — the same charts `4-deploy-fantaco-backends.sh` renders —
with the four non-demo components disabled.

### Sync waves

```
-30  cluster-prereqs      UWM, ClusterRole
-20  rhoai, odf-mcg       operators and their CRs
-15  claw-operator        (opt-in)
-10  maas                 gateway, DB, RHCL, model chain, governance
  0  observability        LokiStack, MLflow
  5  mlflow               upstream chart at its pinned SHA
 10  seats                Claw CR, quota, policies
 11  seats-fantaco-app    REST backends + Postgres
 12  seats-fantaco-mcp    MCP servers
 15  seat RoleBindings    (namespaces exist by now)
 20  mcp-catalog, broker
```

The ordering is not cosmetic. `extend-cluster.sh` has to run before
`0-admin-setup.sh` for exactly the reason wave 15 exists: RBAC inside a
namespace that does not exist yet fails.

## What stays imperative, and why

This is the honest part. Four things are not here, and none of them is an
omission — each is something that cannot be a resource.

**1. Per-seat MaaS keys.** `sk-oai-…` keys *cannot be known in advance*;
they only exist once the chain is Ready and the MaaS API mints them. The
seat chart therefore references the `litellm-api-key` secret but does not
manage its contents, so a resync cannot overwrite a live key.

```bash
./maas-mint-seat-keys.sh --smoke-test     # ALWAYS, before the fleet
./maas-mint-seat-keys.sh --apply 1 100
```

The smoke test is the only thing that catches a missing `ipp-managed`
label — though with this chart creating the secret, that should no longer
be reachable.

**2. Skills and plugins inside the pod.** `6-inject-enterprise-skills.sh`
copies into a running container's filesystem. Anything copied into a pod
after creation lands unreliably at fleet scale: ~2.5% of seats silently
miss the seeded skill, ~10% miss the npm plugin install. GitOps does not
change that; only a baked image would.

**3. The heartbeat.** It is governed by the presence of a file inside the
PVC, inverted: a *missing* `workspace/HEARTBEAT.md` arms it. Not a cluster
resource at all.

**4. The broker audience code.** Derived at runtime from the route
hostnames. `update-broker-ocp.sh` reads it back; the broker's own
`stats.audience_id` is authoritative.

Two further things run as PostSync **hook Jobs** rather than resources,
because both mutate objects an operator owns:

- `components/maas/templates/authorino-cert-job.yaml` — annotates the
  Authorino Service so service-ca mints its listener cert.
- `components/observability/templates/loki-s3-secret-job.yaml` — waits
  for the ObjectBucketClaim to bind, then translates its generated
  credentials into the Secret shape the Loki Operator wants.

And one restart that no resource expresses: if `MaaSAuthPolicy` sits at
`Ready=Unknown`, RHOAI's controllers cached the absence of the Kuadrant
APIs. Restart them:

```bash
oc delete pod -n redhat-ods-applications -l app=odh-model-controller
oc delete pod -n redhat-ods-applications -l control-plane=kserve-controller-manager
```

## Verifying

**Verify by counting, never by exit code**, and that applies to Argo too:
`Synced/Healthy` means the resources exist, not that the demo works.
Several of these steps report success while having done nothing — that is
how 100 seats once ended up with invisible skills.

```bash
./demo-preflight.sh --site ocp 1 <N>     # expect 19/19 per seat
./demo-urls.sh --site ocp
```

Spot checks that catch what preflight does not:

```bash
# Metrics really scraping — every target should be 1
up{namespace=~"agentic-user.*"}          # via the thanos-querier route

# MCP servers up. 406 is UP (it wants the MCP Accept header); 404 is not.
curl -s -o /dev/null -w '%{http_code}\n' http://mcp-customer-service.agentic-user1:9001/mcp
```

## Images

The six demo images come from **`docker.io/burrsutter`** and that is
deliberate. `quay.io/openclawopenshift` carries the same six names at the
same tags, but the images are **different content**: all three quay
`mcp-server-*` images lack `httpx` and crashloop with
`ModuleNotFoundError`. That took out ~298 pods on one build. Matching
names and tags prove nothing — see commit `4d17d95`.

Above ~60 seats, mirror rather than raise the pull count: 100 namespaces
pulling six images exhausts Docker Hub's anonymous limit around seat 62,
and it presents as a broken demo rather than a quota error.

```bash
./mirror-fantaco-images.sh
# then set images.fantacoPrefix / images.mcpPrefix to the mirror
```

## Changing something

The same rule as the rest of this repository: a convention recorded in one
place is worse than one recorded nowhere. If you change a behaviour here
that [`HANDOFF.md`](../HANDOFF.md) or [`QUICKSTART.md`](../QUICKSTART.md)
also documents, change it there in the same edit.

## Seat identities: two shapes, one password

Who the attendees log in as, and who the seats are bound to, is one
decision with two supported answers. Both need the chart to KNOW the
password, because minting a MaaS key as the seat means logging in as
that seat — and that is what makes usage attributable per seat instead
of collapsing into a single `user="cluster-admin"` row.

**RHDP users — the long-term shape.** The order form already creates
`user1…userN` in Keycloak. Set the password you chose for them and
point the seats at that prefix:

```yaml
seats:
  userPrefix: "user"
  password: "<the password you set on the order>"
components:
  seatIdentities:
    enabled: false        # nothing to create; RHDP already did
```

One identity set, one login button, no second provider to explain.

**htpasswd — what the chart does by default today.** Used when you do
not control the order form's user passwords:

```yaml
seats:
  userPrefix: "agentic-user"
  password: ""            # empty derives one from the GUID
components:
  seatIdentities:
    enabled: true
```

This APPENDS an htpasswd provider to `oauth/cluster` — it never
replaces the list, because replacing it would delete RHDP's Keycloak
provider and lock everyone out of the console. Expect two buttons on
the login page; the htpasswd one owns the seats.

Read a derived password with:

```bash
oc get secret seat-identities-password -n openshift-config \
  -o jsonpath='{.data.password}' | base64 -d
```

**`seats.userPrefix` must match whichever identities actually exist.**
It is what `claw-user` and namespace `admin` are bound to, and a wrong
prefix fails silently: the RoleBindings apply cleanly against
identities that never log in.

**One shared password for every seat** in both shapes. Fine for a
workshop where it goes on a slide; it means any attendee can log in as
any other seat, so rotate or tear the cluster down afterwards. For
genuine per-seat isolation use `../create-seat-users.sh`, which does
bcrypt with distinct passwords into a gitignored CSV — distributing N
different secrets is not something a chart can do well.
