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

{{/*
The daemon pod's name, fixed by the StatefulSet (ordinal 0). The console Role pins
pods / pods/exec / pods/log to exactly this name (#1360). A StatefulSet name over 52
characters breaks its controller-revision-hash label, so fail at render time.
*/}}
{{- define "open-design.daemonPodName" -}}
{{- $sts := include "open-design.fullname" . -}}
{{- if gt (len $sts) 52 -}}
{{- fail (printf "fullname %q is longer than 52 characters (StatefulSet limit)" $sts) -}}
{{- end -}}
{{- printf "%s-0" $sts -}}
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

{{/* ── Omnigent host (shared kit: templates/_omnigent-host.tpl) ─────────────── */}}

{{/* ConfigMap carrying the vendored kit (supervisor, helper, status printer). */}}
{{- define "open-design.omnigentHostConfigMapName" -}}
{{- printf "%s-omnigent-host" (include "open-design.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* OpenDesign's own Omnigent files: workspace seed + the terminal status hook. */}}
{{- define "open-design.omnigentOdConfigMapName" -}}
{{- printf "%s-omnigent-od" (include "open-design.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* omnigent config/data dir on the od-home PVC (the console's `omnigent login` writes here). */}}
{{- define "open-design.omnigentDir" -}}
{{- printf "%s/.omnigent" (.Values.persistence.home.mountPath | toString | trimSuffix "/") -}}
{{- end -}}

{{/* Session workspace: the kit's validation plus "must live on the od-home PVC". */}}
{{- define "open-design.omnigentWorkspace" -}}
{{- $home := .Values.persistence.home.mountPath | toString | trimSuffix "/" -}}
{{- $w := include "woow.omnigentHost.workspace" (dict "root" . "default" (printf "%s/studio" $home)) | trimSuffix "/" -}}
{{- if not (hasPrefix (printf "%s/" $home) $w) -}}
{{- fail (printf "omnigentHost.workspace %q must be inside persistence.home.mountPath (%s) so it survives restarts" $w $home) -}}
{{- end -}}
{{- $w -}}
{{- end -}}

{{/* Strict booleans for the OpenDesign-specific omnigentHost flags. A missing key falls
     back to .default ("true" unless the caller passes "default" false). */}}
{{- define "open-design.omnigentFlag" -}}
{{- $v := .root.Values.omnigentHost | default dict -}}
{{- if not (hasKey $v .key) -}}{{ ternary "true" "" (ternary .default true (hasKey . "default")) }}
{{- else if kindIs "bool" (get $v .key) -}}{{ ternary "true" "" (get $v .key) }}
{{- else -}}{{ fail (printf "omnigentHost.%s must be true or false, got %v" .key (get $v .key)) }}
{{- end -}}
{{- end -}}

{{/*
OpenDesign's own Omnigent files (not part of the shared kit): the session-workspace
seed, mounted read-only at /etc/omnigent-host-seed (OG_WORKSPACE_SEED_DIR; flat keys,
"a__b" = "a/b"). No credentials. Rendered by omnigent-host-configmap.yaml and hashed
into the pod's checksum/omnigent-od annotation.
*/}}
{{- define "open-design.omnigentOdConfigMap" -}}
{{- $odUrl := include "open-design.publicUrl" . -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "open-design.omnigentOdConfigMapName" . }}
  labels:
    {{- include "open-design.labels" . | nindent 4 }}
data:
  # OpenDesign MCP server (stdio) for Claude Code sessions in the workspace — what
  # `od mcp install claude` registers, but project-scoped so OpenDesign's own agent
  # runs do not see it. Runs inside the daemon container (the host's sessions do)
  # and reaches the daemon over loopback (no token needed there).
  .mcp.json: |
    {
      "mcpServers": {
        "open-design": {
          "type": "stdio",
          "command": "/usr/local/bin/node",
          "args": ["/app/apps/daemon/dist/cli.js", "mcp", "--daemon-url", "http://127.0.0.1:{{ int .Values.service.targetPort }}"],
          "env": {"OD_DATA_DIR": {{ .Values.persistence.data.mountPath | quote }}}
        }
      }
    }
  .claude__settings.json: |-
{{ .Files.Get "files/omnigent-workspace/claude-settings.json" | indent 4 }}
  CLAUDE.md: |-
{{ .Files.Get "files/omnigent-workspace/CLAUDE.md" | replace "@@OD_PUBLIC_URL@@" (ternary $odUrl "（請向管理員索取 OpenDesign 網址）" (ne $odUrl "")) | indent 4 }}
{{- end -}}

{{/*
Pod securityContext: .Values.podSecurityContext plus fsGroupChangePolicy
OnRootMismatch whenever fsGroup is set (also after --reuse-values from 0.2.1). Without
it the kubelet chmods both PVCs recursively on every mount, turning omnigent's 0600
auth_tokens.json into 0660 and slowing every start.
*/}}
{{- define "open-design.podSecurityContext" -}}
{{- $p := deepCopy (.Values.podSecurityContext | default dict) -}}
{{- if and (hasKey $p "fsGroup") (not (hasKey $p "fsGroupChangePolicy")) -}}
{{- $_ := set $p "fsGroupChangePolicy" "OnRootMismatch" -}}
{{- end -}}
{{- /* 0.5.1 (AI-OD-007-4): RuntimeDefault seccomp for EVERY container of the pod
       (initContainers seed-home / authproxy-init and the authproxy sidecar had none).
       Defaulted here, not only in values, so a --reuse-values upgrade gets it too. */ -}}
{{- if not (hasKey $p "seccompProfile") -}}
{{- $_ := set $p "seccompProfile" (dict "type" "RuntimeDefault") -}}
{{- end -}}
{{- if $p }}{{ toYaml $p }}{{ end -}}
{{- end -}}

{{/*
Container securityContext for the nginx auth-proxy sidecar and its htpasswd init
container (image nginxinc/nginx-unprivileged, uid/gid 101). 0.5.1 (AI-OD-007-4): they had no
securityContext at all (PSA baseline let them through; restricted warned). Same
override-the-defaults pattern as the daemon: .Values.authProxy.securityContext wins.
readOnlyRootFilesystem stays off: nginx writes its temp dirs (client_temp, ...) under /tmp.
*/}}
{{- define "open-design.authProxySecurityContext" -}}
{{- $d := dict "runAsNonRoot" true "runAsUser" 101 "runAsGroup" 101 "allowPrivilegeEscalation" false "privileged" false "capabilities" (dict "drop" (list "ALL")) "seccompProfile" (dict "type" "RuntimeDefault") -}}
{{- /* top-level keys of the tenant/platform value replace the defaults — also `false`: sprig's merge
       treats false as empty and would let the default win */ -}}
{{- range $k, $v := ((.Values.authProxy).securityContext | default dict) }}{{ $_ := set $d $k $v }}{{ end -}}
{{- toYaml $d -}}
{{- end -}}

{{/*
Container securityContext for the console (Flask + ttyd + kubectl). 0.5.1 (AI-OD-007-4): it ran
as root with the default capability set (CapEff a80425fb: NET_RAW, SETUID, DAC_OVERRIDE, ...),
no seccomp, privilege escalation allowed. Now uid/gid console.runAsUser, no capabilities,
RuntimeDefault, no privilege escalation, read-only root filesystem: the app copy goes to the
emptyDir /app and HOME is the emptyDir /tmp (kubectl's cache). Only for the baked image —
console.runtimeInstall (apt-get / pip at start) needs root and stays unrestricted.
.Values.console.securityContext overrides these defaults key by key.
*/}}
{{- define "open-design.consoleSecurityContext" -}}
{{- if not .Values.console.runtimeInstall -}}
{{- $u := int (.Values.console.runAsUser | default 10002) -}}
{{- $d := dict "runAsNonRoot" true "runAsUser" $u "runAsGroup" $u "allowPrivilegeEscalation" false "privileged" false "readOnlyRootFilesystem" true "capabilities" (dict "drop" (list "ALL")) "seccompProfile" (dict "type" "RuntimeDefault") -}}
{{- range $k, $v := ((.Values.console).securityContext | default dict) }}{{ $_ := set $d $k $v }}{{ end -}}
{{- toYaml $d -}}
{{- end -}}
{{- end -}}

{{/*
Container securityContext for the daemon (which also runs the Omnigent host and its
sessions) and its agent-defaults / prune-runs init containers: hardened defaults UNDER
.Values.securityContext, so the defaults also apply after a --reuse-values upgrade that
still carries `securityContext: {}`, while an explicit value wins.
0.5.5 (AI-FIX-OD-1-1): top-level keys are set one by one, as for the console and the auth
proxy above. sprig's merge treats `false` as empty, so `runAsNonRoot: false` rendered the
default true — only overrides towards true (allowPrivilegeEscalation: true) took effect.
*/}}
{{- define "open-design.containerSecurityContext" -}}
{{- $d := dict "runAsNonRoot" true "runAsUser" 1001 "runAsGroup" 1001 "allowPrivilegeEscalation" false "privileged" false "capabilities" (dict "drop" (list "ALL")) "seccompProfile" (dict "type" "RuntimeDefault") -}}
{{- range $k, $v := (.Values.securityContext | default dict) }}{{ $_ := set $d $k $v }}{{ end -}}
{{- toYaml $d -}}
{{- end -}}

{{/*
NetworkPolicy egress peer for the same-namespace Omnigent server. Defaults apply
when networkPolicy.omnigentEgress is missing (--reuse-values from 0.2.1). When
omnigentHost.serverUrl is an in-cluster URL http://<rel>-omnigent[.<this ns>[.svc[.cluster.local]]]:<port>,
the pod selector also pins app.kubernetes.io/instance=<rel>.
Prints "" when no rule should be rendered.
*/}}
{{- define "open-design.omnigentEgress" -}}
{{- $e := .Values.networkPolicy.omnigentEgress | default dict -}}
{{- $on := ternary $e.enabled true (hasKey $e "enabled") -}}
{{- if and $on (include "woow.omnigentHost.enabled" .) -}}
{{- $labels := deepCopy ($e.podLabels | default (dict "app.kubernetes.io/name" "omnigent" "app.kubernetes.io/component" "server")) -}}
{{- $ports := $e.ports | default (list 8000) -}}
{{- $url := include "woow.omnigentHost.serverUrl" . -}}
{{- if $url -}}
{{- $h := (urlParse $url).host | splitList ":" | first -}}
{{- $ns := .Release.Namespace -}}
{{- $m := regexFind (printf "^[a-z0-9]([-a-z0-9]*[a-z0-9])?-omnigent(\\.%s(\\.svc(\\.cluster\\.local)?)?)?$" (regexQuoteMeta $ns)) $h -}}
{{- if $m -}}
{{- $_ := set $labels "app.kubernetes.io/instance" (regexReplaceAll "-omnigent(\\..*)?$" $h "") -}}
{{- end -}}
{{- end -}}
{{- toYaml (dict "podLabels" $labels "ports" $ports) -}}
{{- end -}}
{{- end -}}

{{/* Public OpenDesign URL for links in the seeded CLAUDE.md: the first entry of
     config.allowedOrigins (the platform pins the tenant origin there), or "". */}}
{{- define "open-design.publicUrl" -}}
{{- $o := .Values.config.allowedOrigins | toString | trim -}}
{{- if and $o (ne $o "*") -}}
{{- (split "," $o)._0 | trim | trimSuffix "/" -}}
{{- end -}}
{{- end -}}

{{/* ── Out-of-the-box agent (#1437 / #1438) ─────────────────────────────────── */}}
{{- define "open-design.agentDefaultsConfigMapName" -}}
{{- printf "%s-agent-defaults" (include "open-design.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* "true" when the agent-defaults initContainer is rendered (a --reuse-values upgrade
     from a chart without the block renders it too). */}}
{{- define "open-design.agentDefaultsEnabled" -}}
{{- $a := .Values.agentDefaults | default dict -}}
{{- if ternary $a.enabled true (hasKey $a "enabled") -}}true{{- end -}}
{{- end -}}

{{/* "true" when the prune-runs initContainer is rendered (default on, also after a
     --reuse-values upgrade from a chart without the runsPrune block). */}}
{{- define "open-design.runsPruneEnabled" -}}
{{- $a := .Values.runsPrune | default dict -}}
{{- if ternary $a.enabled true (hasKey $a "enabled") -}}true{{- end -}}
{{- end -}}

{{- define "open-design.agentDefaultAgent" -}}
{{- $a := .Values.agentDefaults | default dict -}}
{{- $d := ($a.defaultAgent | default "auto") | toString -}}
{{- if not (regexMatch "^(auto|keep|[a-z][a-z0-9-]{0,31})$" $d) -}}
{{- fail (printf "agentDefaults.defaultAgent %q must be auto, keep or an agent id (claude, opencode, …)" $d) -}}
{{- end -}}
{{- $d -}}
{{- end -}}

{{- define "open-design.opencodeModel" -}}
{{- $a := .Values.agentDefaults | default dict -}}
{{- $m := (ternary $a.opencodeModel "openrouter/openai/gpt-5-mini" (hasKey $a "opencodeModel")) | default "" | toString | trim -}}
{{- if and $m (not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._/:@-]*$" $m)) -}}
{{- fail (printf "agentDefaults.opencodeModel %q must be an OpenCode model id provider/model (e.g. openrouter/openai/gpt-5-mini)" $m) -}}
{{- end -}}
{{- $m -}}
{{- end -}}

{{/*
API-key checksum for the daemon pod template (#1435). The keys reach the daemon as
secretKeyRef env vars, read once at container start, so a key change must roll the pod.
Hashes ONLY the LLM keys (never admin_password: a password reset reaches nginx through
the Secret volume without a daemon restart, #1360). With auth.existingSecret the keys
live in that Secret, read via lookup (empty during `helm template`).
*/}}
{{- define "open-design.apiKeysChecksum" -}}
{{- $a := .Values.auth | default dict -}}
{{- /* "keys-always-rendered" (#1556, 0.4.5): changes the hash once, so the upgrade to
       this version restarts the daemon and a key cleared before the fix (stale in the
       Secret, now overwritten with "") leaves the running process too. */ -}}
{{- $keys := list "keys-always-rendered" ($a.anthropicApiKey | default "") ($a.openrouterApiKey | default "") -}}
{{- with $a.existingSecret -}}
{{- $s := lookup "v1" "Secret" $.Release.Namespace . -}}
{{- $d := (get ($s | default dict) "data") | default dict -}}
{{- $keys = list . (get $d "ANTHROPIC_API_KEY" | default "") (get $d "OPENROUTER_API_KEY" | default "") -}}
{{- end -}}
{{- join "\n" $keys | sha256sum -}}
{{- end -}}

{{/* White-label support page (#1439): an absolute http(s) URL, rendered inside an nginx
     quoted string — no whitespace, quotes, backslashes, `$` or `;`. */}}
{{- define "open-design.supportUrl" -}}
{{- $u := ((.Values.whiteLabel | default dict).supportUrl | default "https://aiot.woowtech.io/woow") | toString | trim -}}
{{- if not (regexMatch "^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[^[:space:][:cntrl:]\"'\\$;{}`]*)?$" $u) -}}
{{- fail (printf "whiteLabel.supportUrl %q must be an absolute http(s) URL without spaces, quotes, $ or ;" $u) -}}
{{- end -}}
{{- $u -}}
{{- end -}}

{{/*
Built-in MCP server settings (0.5.0): .Values.mcp merged over the defaults, so a
--reuse-values upgrade from <= 0.4.x (no `mcp` key at all) renders as mcp.enabled=false.
Returns YAML; use with fromYaml.
*/}}
{{- define "open-design.mcp" -}}
{{- $d := dict "enabled" false "port" 8081 "dataSubPath" ".woow-mcp" "runAsUser" 10001 "runAsGroup" 10001
      "resources" (dict
        "requests" (dict "cpu" "50m" "memory" "160Mi" "ephemeral-storage" "16Mi")
        "limits" (dict "cpu" "500m" "memory" "320Mi" "ephemeral-storage" "128Mi")) -}}
{{- toYaml (merge (deepCopy (.Values.mcp | default dict)) $d) -}}
{{- end -}}

{{/*
The service's public origin for the MCP admin page's client endpoint (<origin>/mcp): the
first entry of config.allowedOrigins that is a plain scheme://host[:port] (the platform
injects https://<tenant-host>). "" when there is none; the tenant then enters the
endpoint on /mcp-admin/ once.
*/}}
{{- define "open-design.publicOrigin" -}}
{{- $found := "" -}}
{{- range splitList "," (.Values.config.allowedOrigins | default "" | toString) -}}
{{- $o := . | trim | trimSuffix "/" | lower -}}
{{- if and (not $found) (regexMatch "^https?://[a-z0-9.-]+(:[0-9]{1,5})?$" $o) -}}
{{- $found = $o -}}
{{- end -}}
{{- end -}}
{{- $found -}}
{{- end -}}
