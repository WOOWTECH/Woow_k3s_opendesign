{{/*
Chart name, overridable.
*/}}
{{- define "opendesign.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name. `helm install opendesign .` yields plain
"opendesign" for every object, which is what the docs and the NPM proxy host
assume; a differently named release simply gets its own prefix instead of
colliding with an existing one.
*/}}
{{- define "opendesign.fullname" -}}
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

{{- define "opendesign.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Selector labels. `app` mirrors the live pi-agent fleet convention
(app=<release>), which is what the NetworkPolicy podSelector and the backup
CronJob's podAffinity match on.
*/}}
{{- define "opendesign.selectorLabels" -}}
app: {{ include "opendesign.fullname" . }}
app.kubernetes.io/name: {{ include "opendesign.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "opendesign.labels" -}}
{{ include "opendesign.selectorLabels" . }}
{{ include "opendesign.nonSelectorLabels" . }}
{{- end -}}

{{/*
The public origin, validated. Empty or non-https is a hard render failure --
the value drives OD_ALLOWED_ORIGINS, and getting it wrong silently disables
OpenDesign's cross-site rejection.
*/}}
{{- define "opendesign.publicUrl" -}}
{{- $url := required "publicUrl is required: set it to the https:// origin this instance is reached on through Nginx Proxy Manager, e.g. --set publicUrl=https://od-woow-k3s.woowtech.io" .Values.publicUrl -}}
{{- if not (regexMatch "^https://[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(:[0-9]{1,5})?$" $url) -}}
{{- fail (printf "publicUrl must be an https:// origin with no path, e.g. https://od-woow-k3s.woowtech.io (got %q)" $url) -}}
{{- end -}}
{{- $url -}}
{{- end -}}

{{/*
Image reference: digest wins over tag. "latest" is rejected outright -- an
unpinned tag is exactly what made the previous chart unreproducible.
*/}}
{{- define "opendesign.image" -}}
{{- $tag := default .Chart.Version .Values.image.tag -}}
{{- if eq (lower (toString $tag)) "latest" -}}
{{- fail "image.tag must not be \"latest\": pin an immutable tag or set image.digest" -}}
{{- end -}}
{{- if .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" .Values.image.digest) -}}
{{- fail (printf "image.digest must look like sha256:<64 hex> (got %q)" .Values.image.digest) -}}
{{- end -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository (toString $tag) -}}
{{- end -}}
{{- end -}}

{{- define "opendesign.nginxImage" -}}
{{- $tag := toString .Values.nginx.image.tag -}}
{{- if eq (lower $tag) "latest" -}}
{{- fail "nginx.image.tag must not be \"latest\"" -}}
{{- end -}}
{{- printf "%s:%s" .Values.nginx.image.repository $tag -}}
{{- end -}}

{{/*
Labels that are NOT part of any selector.

The Service and the Deployment both select on `opendesign.selectorLabels`, so
any pod that carries the full label set joins the Service's EndpointSlice --
including short-lived helper pods that listen on nothing. The `helm test` hook
pod therefore carries only these labels plus a component marker, which is why
`helm test` cannot black-hole live traffic on port {{ .Values.nginx.port }}.
*/}}
{{- define "opendesign.nonSelectorLabels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: opendesign
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "opendesign.chart" . }}
{{- end -}}

{{/*
Name of the Secret that supplies extra environment to the OpenDesign
container. Defaults to <fullname>-extra-env; `create: false` means the Secret
is expected to exist already (created out of band, never by this chart).
*/}}
{{- define "opendesign.extraEnvSecretName" -}}
{{- $cfg := .Values.opendesign.extraEnvSecret -}}
{{- if $cfg.name -}}
{{- $cfg.name -}}
{{- else -}}
{{- printf "%s-extra-env" (include "opendesign.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Keys that must never be supplied from outside the chart, and the credential
shape guard.

`opendesign.extraEnv` lands in the -config ConfigMap in CLEARTEXT: a ConfigMap
is readable by anything with get on ConfigMaps in the namespace and is echoed
back by `helm get values`. Credentials belong in
`opendesign.extraEnvSecret` instead. `rejectSecretShapedExtraEnv: true` turns
that from advice into a render failure; it ships false because the live
release still carries one such key and this chart may not change a running
pod's environment by surprise.
*/}}
{{- define "opendesign.validateExtraEnv" -}}
{{- $reserved := list "OD_BIND_HOST" "OD_PORT" "OD_DATA_DIR" "OD_ALLOWED_ORIGINS" "OD_PUBLIC_BASE_URL" "OD_API_TOKEN" "OD_DISABLE_API_AUTH" "HOME" "PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH" "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD" -}}
{{- $secretCfg := .Values.opendesign.extraEnvSecret -}}
{{- $secretData := $secretCfg.data | default dict -}}
{{- range $k, $v := .Values.opendesign.extraEnv -}}
{{- if has $k $reserved -}}
{{- fail (printf "opendesign.extraEnv must not set %s: it is chart-owned. OD_API_TOKEN and OD_DISABLE_API_AUTH in particular are unnecessary behind a loopback bind and must never be set here." $k) -}}
{{- end -}}
{{- if hasKey $secretData $k -}}
{{- fail (printf "%s is set in BOTH opendesign.extraEnv and opendesign.extraEnvSecret.data. envFrom order would decide which one wins; pick one." $k) -}}
{{- end -}}
{{- if $.Values.opendesign.rejectSecretShapedExtraEnv -}}
{{- if regexMatch "(?i)(_?API_?KEY|_?TOKEN|_?SECRET|_?PASSWORD|_?PASSWD)$" $k -}}
{{- fail (printf "opendesign.extraEnv.%s looks like a credential and opendesign.extraEnv is rendered into a cleartext ConfigMap. Move it to opendesign.extraEnvSecret (set enabled: true and reference an existing Secret), or set opendesign.rejectSecretShapedExtraEnv: false to accept the cleartext." $k) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- range $k, $v := $secretData -}}
{{- if has $k $reserved -}}
{{- fail (printf "opendesign.extraEnvSecret.data must not set %s: it is chart-owned." $k) -}}
{{- end -}}
{{- end -}}
{{- if and $secretCfg.create (not $secretCfg.enabled) -}}
{{- fail "opendesign.extraEnvSecret.create: true has no effect while opendesign.extraEnvSecret.enabled is false -- the Deployment would never read the Secret. Set enabled: true." -}}
{{- end -}}
{{- if and $secretCfg.enabled $secretCfg.create (not $secretData) -}}
{{- fail "opendesign.extraEnvSecret.create: true requires opendesign.extraEnvSecret.data to hold at least one key. Leave create: false to reference a Secret that already exists." -}}
{{- end -}}
{{- if and $secretData (not $secretCfg.create) -}}
{{- fail "opendesign.extraEnvSecret.data is set but create is false, so nothing renders it and those values would silently never reach the container. Set create: true, or drop data and create the Secret out of band." -}}
{{- end -}}
{{- end -}}
