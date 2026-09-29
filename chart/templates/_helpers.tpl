{{/*
open-design helm chart helpers.

Per-instance service running the OpenDesign daemon (+ optional console). Deployed
per-tenant by paas-operator with release name svc-{reference_id[:8]} into a
paas-ws-* namespace.
*/}}

{{- define "open-design.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "open-design.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "open-design.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* ── Daemon labels ───────────────────────────────────────────────────────── */}}

{{/* Selector labels (stable across versions — used by Deployment/Service selectors). */}}
{{- define "open-design.selectorLabels" -}}
app.kubernetes.io/name: {{ include "open-design.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Common labels. */}}
{{- define "open-design.labels" -}}
helm.sh/chart: {{ include "open-design.chart" . }}
{{ include "open-design.selectorLabels" . }}
app.kubernetes.io/component: daemon
app.kubernetes.io/part-of: open-design
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end -}}

{{/* ── Console labels ──────────────────────────────────────────────────────── */}}

{{- define "open-design.console.selectorLabels" -}}
app.kubernetes.io/name: {{ include "open-design.name" . }}-console
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "open-design.console.labels" -}}
helm.sh/chart: {{ include "open-design.chart" . }}
{{ include "open-design.console.selectorLabels" . }}
app.kubernetes.io/component: console
app.kubernetes.io/part-of: open-design
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end -}}

{{/* ── Names ───────────────────────────────────────────────────────────────── */}}

{{- define "open-design.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "open-design.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Daemon Service name — service.name override, else the release fullname. */}}
{{- define "open-design.serviceName" -}}
{{- default (include "open-design.fullname" .) .Values.service.name -}}
{{- end -}}

{{- define "open-design.configMapName" -}}
{{- printf "%s-config" (include "open-design.fullname" .) -}}
{{- end -}}

{{- define "open-design.secretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- .Values.auth.existingSecret -}}
{{- else -}}
{{- printf "%s-secrets" (include "open-design.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* nginx auth-proxy config ConfigMap name. */}}
{{- define "open-design.authProxyConfigMapName" -}}
{{- printf "%s-authproxy" (include "open-design.fullname" .) -}}
{{- end -}}

{{- define "open-design.dataPvcName" -}}
{{- printf "%s-data" (include "open-design.fullname" .) -}}
{{- end -}}

{{- define "open-design.homePvcName" -}}
{{- printf "%s-home" (include "open-design.fullname" .) -}}
{{- end -}}

{{/* ── Console names ───────────────────────────────────────────────────────── */}}

{{- define "open-design.console.fullname" -}}
{{- printf "%s-console" (include "open-design.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "open-design.console.serviceAccountName" -}}
{{- include "open-design.console.fullname" . -}}
{{- end -}}

{{- define "open-design.console.scriptsConfigMapName" -}}
{{- printf "%s-scripts" (include "open-design.console.fullname" .) -}}
{{- end -}}

{{/*
Resolve the daemon API token / TUI password with self-generate + persist:
  (1) explicit .Values.auth.<field> wins (platform helm_default_values / --set);
  (2) else reuse the value already in the live chart-managed Secret so `helm
      upgrade` does NOT regenerate it (a naive rand would churn the Secret every
      sync); only generate when none exists yet.
Ignored entirely when auth.existingSecret is set (chart creates no Secret).
Usage: {{ include "open-design.resolveSecretValue" (dict "ctx" . "explicit" .Values.auth.odApiToken "key" "OD_API_TOKEN" "gen" "hex32") }}
*/}}
{{- define "open-design.resolveSecretValue" -}}
{{- $ctx := .ctx -}}
{{- $val := .explicit -}}
{{- if not $val -}}
  {{- $live := lookup "v1" "Secret" $ctx.Release.Namespace (include "open-design.secretName" $ctx) -}}
  {{- if $live -}}
    {{- with $live.data -}}
      {{- with (index . $.key) -}}
        {{- $val = . | b64dec -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if not $val -}}
  {{- if eq .gen "hex32" -}}
    {{- $val = randAlphaNum 64 | lower | trunc 64 -}}
  {{- else -}}
    {{- $val = randAlphaNum 24 -}}
  {{- end -}}
{{- end -}}
{{- $val -}}
{{- end -}}

{{/*
Image used by the seed-home initContainer. homeSeed.image overrides; otherwise
the DAEMON image itself — it already ships /etc/skel and is guaranteed present
on the node (no extra pull secret, no extra egress, no version skew).
*/}}
{{- define "open-design.homeSeedImage" -}}
{{- if .Values.homeSeed.image -}}
{{- .Values.homeSeed.image -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}
{{- end -}}

{{/*
Tenant basic-auth username — ONE credential for the auth-proxy htpasswd and the
console (ttyd -c + Flask dashboard). The platform lets tenants change it, so it
is validated here rather than trusted: it is written verbatim into an htpasswd
line (`user:{PLAIN}pw`, nginx splits on the FIRST ':') and into ttyd's
`-c user:pw` argument. A ':' or whitespace would silently split the credential
into a different user/password pair; an empty value would lock everyone out.
Fail the render instead — helm keeps the old release, the tenant keeps access.
*/}}
{{- define "open-design.basicAuthUsername" -}}
{{- $u := .Values.authProxy.basicAuth.username | toString -}}
{{- if not (regexMatch "^[A-Za-z0-9._@-]{1,64}$" $u) -}}
{{- fail (printf "authProxy.basicAuth.username %q is invalid: 1-64 characters from A-Z a-z 0-9 . _ @ -" $u) -}}
{{- end -}}
{{- $u -}}
{{- end -}}
