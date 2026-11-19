# claw-operator — why this is off by default

There is no chart in this directory on purpose. When
`components.clawOperator.enabled` is true, the root chart creates an Argo
Application pointing straight at the upstream repository's kustomize
overlay:

```
repoURL: https://github.com/codeready-toolchain/claw-operator.git
path:    config/default
```

Three things make that less turnkey than the other components, and all
three are reasons to look before enabling it.

**1. Upstream ships a Makefile, not a bundle.** `0-admin-setup.sh` runs
`make dev-deploy REGISTRY=… TAG=…`, which renders CRDs *from the working
tree*. A stale checkout therefore applies stale CRDs. Pointing Argo at
`config/default` at a pinned revision is strictly better than that — but
the kustomize overlay has not been verified to produce an identical
deployment, so check it before relying on it.

**2. The pinned image needs a patch.** `claw-operator:554d988` writes
`mcpBucketAServers` from a Go map without sorting. With several URL-based
MCP servers — which is exactly this demo — repeated reconciliations change
the gateway ConfigMap hash and restart gateway pods indefinitely. Apply
[`../../../operator-patches/0001-sort-mcp-bucket-a.patch`](../../../operator-patches/0001-sort-mcp-bucket-a.patch)
to the matching source and build an image per cluster; see
[`operator-patches/README.md`](../../../operator-patches/README.md).

Point `images.clawOperatorRegistry` / `images.clawOperatorTag` at that
built image rather than the upstream tag.

**3. Memory limits and RBAC.** The script patches the controller to
`512Mi` limit / `128Mi` request with a JSON patch — deliberately not a
merge patch, because `--type=merge` on `containers` replaces the whole
array and loses env vars such as `PROXY_IMAGE`. It also grants the
operator SA cluster-admin. Neither is in the upstream overlay; add them
as a kustomize patch in your own overlay if you enable this.

Until those are settled, leave this false and install the operator with
`0-admin-setup.sh` as before. It is idempotent and skips cleanly when the
operator is already running.
