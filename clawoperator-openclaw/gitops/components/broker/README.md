# broker — why this is off by default

When `components.broker.enabled` is true, the root chart creates a plain
directory Application over
[`../../../broker-pg/openshift`](../../../broker-pg/openshift): the
CloudNativePG operator, `broker-db.yaml` and `broker.yaml`. Those are
already finished manifests; re-expressing them as a chart would add
nothing.

Two reasons it does not sync cleanly on a fresh cluster.

**1. The image does not exist yet.** `broker.yaml` pulls
`image-registry.openshift-image-registry.svc:5000/session-broker/session-broker:latest`,
which `deploy-broker-ocp.sh` builds in-cluster from `broker-pg/`. Run
that once first, or add a BuildConfig to this directory and let Argo own
the build too.

**2. The audience code is runtime state, not configuration.** The broker
derives its audience id from the route hostnames (`claw-<code>-<user>`)
and keeps assignments in its database. `update-broker-ocp.sh` injects the
route list and reads the id back; the broker's own `stats.audience_id` is
authoritative, not anything in git.

So the broker's *deployment* is declarative and its *contents* are not:

```bash
./deploy-broker-ocp.sh                      # once, builds the image
./update-broker-ocp.sh --rotate-status-key  # after every seat change
```

Note that `--reset` keeps the audience code despite what the help text
says — `/admin/reset` re-derives it from the route hostnames, so the URL
and QR survive and only assignments are wiped.

`selfHeal` is deliberately **off** on this Application. The broker's
Deployment is edited at runtime by the update script; self-healing would
fight it.
