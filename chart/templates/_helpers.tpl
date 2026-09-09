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
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: opendesign
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "opendesign.chart" . }}
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
Env keys the chart owns. Setting one of these through opendesign.extraEnv is a
render failure rather than a silent override of the security posture.
*/}}
{{- define "opendesign.validateExtraEnv" -}}
{{- $reserved := list "OD_BIND_HOST" "OD_PORT" "OD_DATA_DIR" "OD_ALLOWED_ORIGINS" "OD_PUBLIC_BASE_URL" "OD_API_TOKEN" "OD_DISABLE_API_AUTH" "HOME" "PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH" "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD" -}}
{{- range $k, $v := .Values.opendesign.extraEnv -}}
{{- if has $k $reserved -}}
{{- fail (printf "opendesign.extraEnv must not set %s: it is chart-owned. OD_API_TOKEN and OD_DISABLE_API_AUTH in particular are unnecessary behind a loopback bind and must never be set here." $k) -}}
{{- end -}}
{{- end -}}
{{- end -}}
