{{/*
omnigent-host chart helpers — WOOW PaaS shared kit (IN-CONTAINER mode).

Canonical copy: woow-paas-charts/shared/omnigent-host/chart/_omnigent-host.tpl.
scripts/sync-omnigent-host-kit.sh vendors it byte-identically into
charts/<chart>/templates/_omnigent-host.tpl (and the runtime files into
charts/<chart>/files/omnigent-host/); never edit a vendored copy.

The omnigent host runs INSIDE the service's main container: the container's
entrypoint wrapper (omnigent-host-launch) starts the kit supervisor in the
background and runs the product; the host dials out to the workspace's
Omnigent service. No extra container, no resource split: the host and its
sessions share the main container's plan limits.

Values contract (see shared/omnigent-host/chart/values-snippet.yaml):
  omnigentHost:
    enabled: true            # default true; false: no kit env/volumes/ConfigMaps,
                             # the product starts exactly as without the kit
    serverUrl: ""            # the same-workspace Omnigent URL (platform-injected).
                             # Rendered ONLY into the runtime ConfigMap, never into
                             # the pod template: changing it never restarts the pod
    hostName: ""             # "" = "<chart> · <release>"
    workspace: ""            # "" = the chart's default (absolute path)
    watchSeconds: 120        # >= 30, login re-check period of a running host

Every helper reads .Values.omnigentHost through "woow.omnigentHost.values", so a
`helm upgrade --reuse-values` from a chart version without the block renders the
defaults instead of failing on a nil map.

Fixed paths (the kit's scripts default to them):
  /etc/omnigent-host           kit ConfigMap (read-only): supervisor.sh,
                               og_helper.py, omnigent-host-launch,
                               omnigent-host-profile.sh, bin/omnigent and
                               bin/omni (guard), bin/omnigent-host-status
  /etc/omnigent-host-runtime   runtime ConfigMap (read-only): server-url
*/}}

{{- define "woow.omnigentHost.kitDir" -}}/etc/omnigent-host{{- end -}}
{{- define "woow.omnigentHost.runtimeDir" -}}/etc/omnigent-host-runtime{{- end -}}

{{/* Effective values as YAML; use: $og := include "woow.omnigentHost.values" . | fromYaml */}}
{{- define "woow.omnigentHost.values" -}}
{{- $v := .Values.omnigentHost | default dict -}}
{{- $out := dict -}}
{{- $_ := set $out "enabled" (ternary $v.enabled true (hasKey $v "enabled")) -}}
{{- $_ := set $out "serverUrl" ($v.serverUrl | default "" | toString) -}}
{{- $_ := set $out "hostName" ($v.hostName | default "" | toString) -}}
{{- $_ := set $out "workspace" ($v.workspace | default "" | toString) -}}
{{- $_ := set $out "watchSeconds" (ternary 120 $v.watchSeconds (kindIs "invalid" $v.watchSeconds)) -}}
{{- toYaml $out -}}
{{- end -}}

{{/* "true" when the in-container host is enabled, "" otherwise (use with `if include ...`). */}}
{{- define "woow.omnigentHost.enabled" -}}
{{- $og := include "woow.omnigentHost.values" . | fromYaml -}}
{{- if eq (toString $og.enabled) "true" -}}true{{- end -}}
{{- end -}}

{{/* Host name shown in Omnigent's machine list; unique per Omnigent account. */}}
{{- define "woow.omnigentHost.hostName" -}}
{{- $og := include "woow.omnigentHost.values" . | fromYaml -}}
{{- $n := $og.hostName | default (printf "%s · %s" .Chart.Name .Release.Name) | trim -}}
{{- if gt (len $n) 120 -}}
{{- fail (printf "omnigentHost.hostName %q is longer than 120 characters" $n) -}}
{{- end -}}
{{- if regexMatch "[[:cntrl:]\"\\\\]" $n -}}
{{- fail (printf "omnigentHost.hostName %q must not contain control characters, quotes or backslashes" $n) -}}
{{- end -}}
{{- $n -}}
{{- end -}}

{{/* Omnigent URL: "" or http(s)://host[:port][/path], no trailing slash, no userinfo/query. */}}
{{- define "woow.omnigentHost.serverUrl" -}}
{{- $og := include "woow.omnigentHost.values" . | fromYaml -}}
{{- $s := $og.serverUrl | trim | trimSuffix "/" -}}
{{- if $s -}}
{{- $u := urlParse $s -}}
{{- if or (not (has $u.scheme (list "http" "https"))) (not $u.host) $u.userinfo $u.query $u.fragment (regexMatch "[[:space:][:cntrl:]\"'\\\\`]" $s) -}}
{{- fail (printf "omnigentHost.serverUrl %q must be http(s)://<host>[:port][/path]" $s) -}}
{{- end -}}
{{- end -}}
{{- $s -}}
{{- end -}}

{{/* Session workspace. Call with (dict "root" $ "default" "/workspace"). */}}
{{- define "woow.omnigentHost.workspace" -}}
{{- $og := include "woow.omnigentHost.values" .root | fromYaml -}}
{{- $w := $og.workspace | default .default | trim -}}
{{- if or (not (hasPrefix "/" $w)) (contains "/../" (printf "%s/" $w)) (regexMatch "[[:cntrl:]]" $w) -}}
{{- fail (printf "omnigentHost.workspace %q must be an absolute path" $w) -}}
{{- end -}}
{{- $w -}}
{{- end -}}

{{/* The image's pinned omnigent CLI (absolute path). Call with the env dict (uses .ogBin). */}}
{{- define "woow.omnigentHost.ogBin" -}}
{{- $b := .ogBin | default "/usr/local/bin/omnigent" | trim -}}
{{- if or (not (hasPrefix "/" $b)) (contains "/../" (printf "%s/" $b)) (hasSuffix "/" $b) (regexMatch "[[:space:][:cntrl:]\"'\\\\`$]" $b) -}}
{{- fail (printf "woow.omnigentHost.env: ogBin %q must be the absolute path of the image's omnigent CLI" $b) -}}
{{- end -}}
{{- $b -}}
{{- end -}}

{{/* Login re-check period; the render fails below 30 s (no busy loops). */}}
{{- define "woow.omnigentHost.watchSeconds" -}}
{{- $og := include "woow.omnigentHost.values" . | fromYaml -}}
{{- $w := $og.watchSeconds -}}
{{- if not (regexMatch "^[0-9]+$" (toString $w)) -}}
{{- fail (printf "omnigentHost.watchSeconds %v must be an integer >= 30" $w) -}}
{{- end -}}
{{- if lt (int $w) 30 -}}
{{- fail (printf "omnigentHost.watchSeconds %v must be >= 30" $w) -}}
{{- end -}}
{{- int $w -}}
{{- end -}}

{{/*
Env entries for the MAIN container (a list fragment; include under `env:`).
Call with a dict:
  root          $ (required)
  configHome    OG_CONFIG_HOME = OMNIGENT_CONFIG_HOME (required): config.yaml
                (server:, host: identity, providers:, telemetry:). The tenant's
                `omnigent login` in this container writes here too.
  dataDir       OG_DATA_DIR = OMNIGENT_DATA_DIR (default: configHome): tokens,
                logs, status, lock
  home          OG_HOME (optional): HOME for the host + sessions when it must
                differ from the product's HOME
  workspace     default session workspace when omnigentHost.workspace is ""
                (default: home; required when home is not given)
  providers     OG_PROVIDERS, e.g. "claude-subscription,pi-original"
  passthrough   OG_PASSTHROUGH, extra env names sessions inherit
  unsetEnv      OG_UNSET_ENV, env names the host must NOT inherit — list the
                product's own login secrets here (e.g. PASSWORD,HASHED_PASSWORD)
  seedDir       OG_WORKSPACE_SEED_DIR (optional): files seeded into the workspace
  seedUpdate    OG_WORKSPACE_SEED_UPDATE: seeded paths updated while unedited
  ogBin         OG_BIN (default /usr/local/bin/omnigent): the image's pinned
                omnigent CLI, an absolute path. The launcher and the supervisor
                run exactly this file, never an `omnigent` found on PATH (a
                tenant can install one in a persistent ~/.local/bin).
Telemetry is switched off for every omnigent process even when the host is
disabled (the tenant can still run the CLI by hand). Never set OG_SERVER_URL
here: the URL lives in the runtime ConfigMap (OG_SERVER_URL_FILE), so changing
it does not change the pod template.
*/}}
{{- define "woow.omnigentHost.env" -}}
{{- $root := .root -}}
# Telemetry off for every omnigent process (also enforced in config.yaml).
- name: OMNIGENT_ANALYTICS
  value: "0"
- name: DO_NOT_TRACK
  value: "1"
- name: DISABLE_TELEMETRY
  value: "1"
{{- if include "woow.omnigentHost.enabled" $root }}
{{- $data := .dataDir | default .configHome }}
{{- $ws := .workspace | default .home }}
# omnigent host in this container (shared/omnigent-host/README.md)
- name: OG_HOST_ENABLED
  value: "1"
- name: OG_KIT_DIR
  value: {{ include "woow.omnigentHost.kitDir" $root | quote }}
- name: OG_SERVER_URL_FILE
  value: {{ printf "%s/server-url" (include "woow.omnigentHost.runtimeDir" $root) | quote }}
- name: OG_CONFIG_HOME
  value: {{ required "woow.omnigentHost.env: configHome is required" .configHome | quote }}
- name: OG_DATA_DIR
  value: {{ $data | quote }}
- name: OMNIGENT_CONFIG_HOME
  value: {{ .configHome | quote }}
- name: OMNIGENT_DATA_DIR
  value: {{ $data | quote }}
- name: OG_STATUS_FILE
  value: {{ printf "%s/omnigent-host/status.json" $data | quote }}
- name: OG_HOST_NAME
  value: {{ include "woow.omnigentHost.hostName" $root | quote }}
- name: OG_WORKSPACE
  value: {{ include "woow.omnigentHost.workspace" (dict "root" $root "default" (required "woow.omnigentHost.env: workspace (or home) is required" $ws)) | quote }}
- name: OG_WATCH_SECONDS
  value: {{ include "woow.omnigentHost.watchSeconds" $root | quote }}
- name: OG_BIN
  value: {{ include "woow.omnigentHost.ogBin" . | quote }}
- name: OG_PROVIDERS
  value: {{ .providers | default "" | quote }}
- name: OG_PASSTHROUGH
  value: {{ .passthrough | default "" | quote }}
- name: OG_UNSET_ENV
  value: {{ .unsetEnv | default "" | quote }}
- name: OMNIGENT_HOST_NO_OPEN
  value: "1"
{{- with .home }}
- name: OG_HOME
  value: {{ . | quote }}
{{- end }}
{{- with .seedDir }}
- name: OG_WORKSPACE_SEED_DIR
  value: {{ . | quote }}
- name: OG_WORKSPACE_SEED_UPDATE
  value: {{ $.seedUpdate | default "" | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
The main container's command (a JSON list) when the CHART launches the product.
Call with (dict "root" $ "init" (list "dumb-init") "command" (list "/usr/bin/entrypoint.sh" "--bind-addr" "0.0.0.0:8080")).
Enabled:  init + ["/bin/sh", "/etc/omnigent-host/omnigent-host-launch", "--"] + command
Disabled: init + command (the product exactly as without the kit)
An image that ships image/omnigent-host-entry in its ENTRYPOINT needs no command
override at all (that stub runs the launcher whenever the kit is mounted).
*/}}
{{- define "woow.omnigentHost.command" -}}
{{- $cmd := required "woow.omnigentHost.command: command is required" .command -}}
{{- if include "woow.omnigentHost.enabled" .root -}}
{{- $cmd = concat (list "/bin/sh" (printf "%s/omnigent-host-launch" (include "woow.omnigentHost.kitDir" .root)) "--") $cmd -}}
{{- end -}}
{{- toJson (concat (.init | default list) $cmd) -}}
{{- end -}}

{{/*
volumeMounts for the main container (a list fragment; include under
`volumeMounts:`; renders nothing when disabled). Call with (dict "root" $
"statusInPath" true): statusInPath (default true) also mounts the status printer
at /usr/local/bin/omnigent-host-status, for shells that never get the kit's bin
on PATH.
*/}}
{{- define "woow.omnigentHost.volumeMounts" -}}
{{- if include "woow.omnigentHost.enabled" .root }}
- name: omnigent-host-kit
  mountPath: {{ include "woow.omnigentHost.kitDir" .root }}
  readOnly: true
# Not a subPath: ConfigMap updates (serverUrl) reach the file without a restart.
- name: omnigent-host-runtime
  mountPath: {{ include "woow.omnigentHost.runtimeDir" .root }}
  readOnly: true
{{- if ne (toString .statusInPath) "false" }}
- name: omnigent-host-kit
  mountPath: /usr/local/bin/omnigent-host-status
  subPath: omnigent-host-status
  readOnly: true
{{- end }}
{{- end }}
{{- end -}}

{{/*
Pod volumes (a list fragment; include under `volumes:`; nothing when disabled).
Call with (dict "root" $ "name" "<kit ConfigMap name>").
*/}}
{{- define "woow.omnigentHost.volumes" -}}
{{- if include "woow.omnigentHost.enabled" .root }}
- name: omnigent-host-kit
  configMap:
    name: {{ .name }}
    defaultMode: 292  # 0444
    items:
      - {key: supervisor.sh, path: supervisor.sh, mode: 365}  # 0555
      - {key: og_helper.py, path: og_helper.py}
      - {key: omnigent-host-launch, path: omnigent-host-launch, mode: 365}
      - {key: omnigent-host-profile.sh, path: omnigent-host-profile.sh}
      - {key: omnigent-host-status, path: omnigent-host-status, mode: 365}
      - {key: omnigent-host-status, path: bin/omnigent-host-status, mode: 365}
      - {key: omnigent-shim, path: bin/omnigent, mode: 365}
      - {key: omnigent-shim, path: bin/omni, mode: 365}
- name: omnigent-host-runtime
  configMap:
    name: {{ printf "%s-runtime" .name }}
    defaultMode: 292  # 0444
{{- end }}
{{- end -}}

{{/*
Pod annotation value that restarts the pod when the KIT changes (never when
serverUrl changes: the runtime ConfigMap is deliberately not part of it).
Call with (dict "root" $ "name" "<kit ConfigMap name>").
*/}}
{{- define "woow.omnigentHost.checksum" -}}
{{- include "woow.omnigentHost.kitConfigMap" . | sha256sum -}}
{{- end -}}

{{/* The kit ConfigMap alone. Call with (dict "root" $ "name" "<name>" "labels" <dict>). */}}
{{- define "woow.omnigentHost.kitConfigMap" -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .name }}
  {{- with .labels }}
  labels:
    {{- toYaml . | nindent 4 }}
  {{- end }}
data:
  supervisor.sh: |
    {{- .root.Files.Get "files/omnigent-host/supervisor.sh" | nindent 4 }}
  og_helper.py: |
    {{- .root.Files.Get "files/omnigent-host/og_helper.py" | nindent 4 }}
  omnigent-host-status: |
    {{- .root.Files.Get "files/omnigent-host/omnigent-host-status" | nindent 4 }}
  omnigent-host-launch: |
    {{- .root.Files.Get "files/omnigent-host/omnigent-host-launch" | nindent 4 }}
  omnigent-host-profile.sh: |
    {{- .root.Files.Get "files/omnigent-host/omnigent-host-profile.sh" | nindent 4 }}
  omnigent-shim: |
    {{- .root.Files.Get "files/omnigent-host/omnigent-shim" | nindent 4 }}
{{- end -}}

{{/*
Both ConfigMaps (kit + runtime "<name>-runtime"); nothing when disabled.
Call with (dict "root" $ "name" "<name>" "labels" <dict>).
The runtime ConfigMap carries only `server-url` (omnigentHost.serverUrl); the
supervisor and omnigent-host-status re-read it at runtime.
*/}}
{{- define "woow.omnigentHost.configMaps" -}}
{{- if include "woow.omnigentHost.enabled" .root }}
{{ include "woow.omnigentHost.kitConfigMap" . }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ printf "%s-runtime" .name }}
  {{- with .labels }}
  labels:
    {{- toYaml . | nindent 4 }}
  {{- end }}
data:
  server-url: {{ include "woow.omnigentHost.serverUrl" .root | quote }}
{{- end }}
{{- end -}}
