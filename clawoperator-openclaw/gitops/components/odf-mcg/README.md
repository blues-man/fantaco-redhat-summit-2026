# odf-mcg

Object storage for Loki, in-cluster, on PVs. No S3 bucket, no public ELB.

## Why there is no `stsWorkaround` flag

The scripted path hits a wall on any cluster whose Cloud Credential
Operator runs in Manual mode (ROSA STS): NooBaa hangs in `Configuring`
forever waiting for `noobaa-aws-cloud-creds-secret`, which CCO never
mints — while the `CredentialsRequest` reports `provisioned: true`. Check
for the **secret**, not the request; `provisioned: true` is not evidence
the credential exists.

The scripted fix is three `oc patch` commands, in this order:

1. `manualDefaultBackingStore: true` on the NooBaa CR (Ready in seconds)
2. create a `pv-pool` BackingStore
3. repoint `noobaa-default-bucket-class`, which is left `Rejected`
   referencing the store that was never created — and which only *exists*
   after step 1

None of the three is expressible as a resource, because all three mutate
objects the operator owns.

So this chart does not patch. It **owns** the NooBaa CR, which turns step
1 into a field; it creates the pv-pool store as step 2 always did; and
instead of repointing the default bucket class it creates its own
`BucketClass` plus a `StorageClass` over it, so the rejected default is
simply never used. The ObjectBucketClaim in `components/observability`
asks for that class by name.

Consequence worth stating: this is now the same on every cluster. A
self-managed OCP-on-AWS cluster would have minted the credential and got
an S3-backed default store; here it gets the in-cluster pv-pool store
instead, which is what the reference architecture asks for anyway.

## pv-pool agent memory

Agent pods default to `requests=limits=400Mi` and get OOMKilled. The
override lives under `pvPool.resources` and, despite the CRD description
("VolumeResources … each volume"), is applied to the **agent container**,
not just the PVC. Re-state `storage` in the same block or the PVC request
is lost.

Keep the request low and the limit high: the limit is what prevents the
OOMKill, the request is what competes with seat workload for scheduling.

## Verifying

The only honest check is an ObjectBucketClaim actually reaching `Bound`.
A NooBaa CR reporting `Ready` says nothing about whether a bucket can be
claimed — and `Ready` is exactly what you get when the default backing
store is missing.

```bash
oc get obc -A
oc get backingstore,bucketclass -n openshift-storage
```
