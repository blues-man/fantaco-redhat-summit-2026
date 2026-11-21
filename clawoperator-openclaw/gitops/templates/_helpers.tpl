{{/*
=====================================================================
THE RHDP CONTRACT
=====================================================================
When this chart is ordered as a Field Sourced Content CI item, the
ocp4_workload_field_content role injects a FIXED set of Helm values on
top of values.yaml. Those key names are not ours to choose, so every
helper below reads the RHDP key first and falls back to our own.

Injected always (roles/ocp4_workload_field_content/tasks/workload.yml):

  deployer.domain        openshift_cluster_ingress_domain
  deployer.apiUrl        openshift_api_url
  gitops.repoURL         the repo you typed in the order form
  gitops.revision        the branch you typed
  gitops.path            the chart path you typed
  litemaas.enabled       true only if you ticked the LiteMaaS box
  litemaas.apiUrl        full URL, e.g. https://litellm-prod.apps.maas…
  litemaas.apiKey        the virtual key, minted per order, expires
  litemaas.model         the model from the dropdown
  multi_user.num_users   when create_multi_user
  multi_user.users       [{username: user1}, …]

Injected by the catalog item (ocp4_workload_field_content_helm_values
in agnosticv agd_v2/ocp-field-asset-aws/common.yaml):

  guid, bases.{virt,rhoai,aap}, user.count,
  openshift.{consoleUrl,adminUsername,adminPassword},
  keycloak.*, aap.*, rhoai.dashboardUrl

NOTE THE CASING: RHDP sets gitops.repoURL (capital URL). A chart that
reads gitops.repoUrl silently keeps pointing at whatever is hardcoded
in values.yaml instead of the repo and branch that was ordered.
*/}}

{{- define "openclaw.labels" -}}
demo.redhat.com/application: "openclaw-on-openshift"
app.kubernetes.io/part-of: openclaw-on-openshift
{{- end -}}

{{/* Repo the child Applications read from. RHDP's order form wins. */}}
{{- define "openclaw.repoURL" -}}
{{- coalesce .Values.gitops.repoURL .Values.gitops.repoUrl -}}
{{- end -}}

{{- define "openclaw.revision" -}}
{{- .Values.gitops.revision | default "main" -}}
{{- end -}}

{{/*
Path to THIS chart inside the repo. RHDP sets gitops.path from the order
form; components live beneath it, so child Applications must use it
rather than a hardcoded basePath.
*/}}
{{- define "openclaw.basePath" -}}
{{- coalesce .Values.gitops.path .Values.gitops.basePath -}}
{{- end -}}

{{/* Cluster GUID. RHDP puts it at the top level, not under deployer. */}}
{{- define "openclaw.guid" -}}
{{- coalesce .Values.guid .Values.deployer.guid "openclaw" -}}
{{- end -}}

{{/*
Seat count.

Precedence: an explicit seats.count wins (someone deliberately set it),
then RHDP's multi_user.num_users, then user.count, then 1. The RHDP
order form's "number of users" is the natural seat count — one agent
seat per attendee is exactly what num_users means here.
*/}}
{{- define "openclaw.seatCount" -}}
{{- if .Values.seats.count -}}
{{- .Values.seats.count -}}
{{- else if and .Values.multi_user .Values.multi_user.num_users -}}
{{- .Values.multi_user.num_users -}}
{{- else if and .Values.user .Values.user.count -}}
{{- .Values.user.count -}}
{{- else -}}
1
{{- end -}}
{{- end -}}

{{/*
=====================================================================
MaaS over MaaS, fed from the LiteMaaS virtual key
=====================================================================
The RHDP virtual key IS the upstream credential this demo needs — the
thing ../.env calls MAAS_UPSTREAM_API_KEY. Ticking "Enable LiteMaaS/MaaS
API Keys" on the order form is what makes the chain work; without it the
MaaSModelRef reaches Ready and the first real inference fails.
*/}}
{{- define "openclaw.maasEnabled" -}}
{{- if or (and .Values.litemaas .Values.litemaas.apiKey) .Values.maas.upstreamApiKey -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{- define "openclaw.maasKey" -}}
{{- if and .Values.litemaas .Values.litemaas.apiKey -}}
{{- .Values.litemaas.apiKey -}}
{{- else -}}
{{- .Values.maas.upstreamApiKey -}}
{{- end -}}
{{- end -}}

{{/*
Upstream endpoint, as an FQDN.

litemaas.apiUrl is a full URL (https://host/…) but ExternalProvider
rejects anything but a bare FQDN — no scheme, no path. The /v1 belongs
in the ExternalModel path. Stripping it here rather than asking whoever
orders the catalog item to strip it.
*/}}
{{- define "openclaw.maasUpstreamEndpoint" -}}
{{- if and .Values.litemaas .Values.litemaas.apiUrl -}}
{{- .Values.litemaas.apiUrl | trimPrefix "https://" | trimPrefix "http://" | splitList "/" | first -}}
{{- else -}}
{{- .Values.maas.upstreamEndpoint -}}
{{- end -}}
{{- end -}}

{{/* Model name. The order form's dropdown wins over values.yaml. */}}
{{- define "openclaw.maasModel" -}}
{{- if and .Values.litemaas .Values.litemaas.model -}}
{{- .Values.litemaas.model -}}
{{- else -}}
{{- .Values.maas.model -}}
{{- end -}}
{{- end -}}

{{/* MaaS gateway hostname: explicit value, else maas.<apps domain>. */}}
{{- define "openclaw.maasGatewayHost" -}}
{{- if .Values.maas.gatewayHost -}}
{{- .Values.maas.gatewayHost -}}
{{- else if .Values.deployer.domain -}}
{{- printf "maas.%s" .Values.deployer.domain -}}
{{- end -}}
{{- end -}}

{{/* What a seat's gateway calls for inference. */}}
{{- define "openclaw.maasApiBase" -}}
{{- printf "https://%s/v1" (include "openclaw.maasGatewayHost" .) -}}
{{- end -}}

{{/*
Context limits for whichever model was actually ordered, falling back
to the conservative default for anything not in the table.
*/}}
{{- define "openclaw.modelLimits" -}}
{{- $m := include "openclaw.maasModel" . -}}
{{- $l := index .Values.maas.modelLimits $m | default .Values.maas.modelLimits.default -}}
{{- toYaml $l -}}
{{- end -}}

{{/*
The one seat password.

seats.password wins; then the legacy
components.seatIdentities.sharedPassword; then one derived from the
GUID so a workshop still works without anyone choosing a value.
Returns "" only if derivation is impossible, which is what makes
asSeat degrade honestly rather than mint as the wrong identity.
*/}}
{{- define "openclaw.seatPassword" -}}
{{- if .Values.seats.password -}}
{{- .Values.seats.password -}}
{{- else if and .Values.components.seatIdentities .Values.components.seatIdentities.sharedPassword -}}
{{- .Values.components.seatIdentities.sharedPassword -}}
{{- else -}}
{{- printf "%s-seats-v1" (include "openclaw.guid" .) | sha256sum | trunc 12 -}}
{{- end -}}
{{- end -}}
