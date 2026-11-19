{{/*
The audience hostname.

audience-reset.sh builds this as claw-<AUDIENCE_CODE>-<USER_CODE>.<apps
domain>, where AUDIENCE_CODE is 5 random hex characters kept in
.state/<guid>/broker.env. Random is right for a script that reruns
between events; it is wrong here, because a value that changes on every
render would give every sync a new hostname and invalidate the QR code.

So the code is derived from the cluster GUID: stable for the life of a
cluster, different between clusters, and reproducible from git alone.
Override audience.code to pin it to whatever the broker already issued.

NOTE the broker is still authoritative for the code it serves. If you
run update-broker-ocp.sh against this cluster, read the code back from
the broker's own stats.audience_id rather than assuming this one.
*/}}
{{- define "seat.audienceCode" -}}
{{- if .Values.audience.code -}}
{{- .Values.audience.code -}}
{{- else -}}
{{- printf "%s-audience" (.Values.deployer.guid | default "openclaw") | sha256sum | trunc 5 -}}
{{- end -}}
{{- end -}}

{{- define "seat.audienceHost" -}}
{{- printf "claw-%s-%s.%s" (include "seat.audienceCode" .) .Values.seat.userCode .Values.cluster.appsDomain -}}
{{- end -}}
