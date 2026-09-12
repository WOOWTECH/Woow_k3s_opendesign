#!/usr/bin/env python3
"""Assertions over the RENDERED chart manifests.

This is the lane the old repo never had. At HEAD 6f742b3 its chart rendered a
literal `__K3S_NODE_HOSTNAME__` nodeSelector, so `helm install` was rejected by
the API server — a defect a single `helm template` + read would have caught.

Reads tests/.artifacts/rendered.yaml (backup enabled) and rendered-minimal.yaml
(backup disabled), produced by tests/lib/extract-chart-assets.py.
"""
from __future__ import annotations

import copy
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import repolayout as layout  # noqa: E402

import yaml  # noqa: E402

RELEASE = "od"
NAMESPACE = "pi-agent-woow"
NGINX_PORT = 7457
DAEMON_PORT = 7456
EGRESS_EXCEPT = ["10.42.0.0/16", "10.43.0.0/16", "192.168.0.0/16", "169.254.169.254/32"]

errors: list[str] = []


def check(condition, message: str) -> None:
    if not condition:
        errors.append(message)


layout.require(
    {
        "tests/.artifacts/rendered.yaml": layout.ARTIFACTS / "rendered.yaml",
        "tests/.artifacts/rendered-minimal.yaml": layout.ARTIFACTS / "rendered-minimal.yaml",
    },
    who="chart manifest assertions (run tests/lib/extract-chart-assets.py first)",
)

rendered_text = (layout.ARTIFACTS / "rendered.yaml").read_text(encoding="utf-8")
docs = [doc for doc in yaml.safe_load_all(rendered_text) if isinstance(doc, dict)]
minimal_docs = [
    doc for doc in yaml.safe_load_all((layout.ARTIFACTS / "rendered-minimal.yaml").read_text(encoding="utf-8"))
    if isinstance(doc, dict)
]


def by_kind(kind: str, source=None) -> list[dict]:
    return [doc for doc in (docs if source is None else source) if doc.get("kind") == kind]


def one(kind: str, source=None) -> dict:
    found = by_kind(kind, source)
    if len(found) != 1:
        check(False, f"expected exactly one {kind}, found {len(found)}")
        return {}
    return found[0]


# ------------------------------------------------------------- object inventory
kinds = sorted(doc.get("kind", "?") for doc in docs)
# The Pod is the `helm test` hook. `helm template` prints hooks, `helm get
# manifest` does not and `helm upgrade` never applies them, so it is part of the
# render but not of the installed object set.
expected_kinds = sorted(["ConfigMap", "ConfigMap", "PersistentVolumeClaim", "PersistentVolumeClaim",
                         "Deployment", "Service", "NetworkPolicy", "CronJob", "Pod"])
check(kinds == expected_kinds, f"rendered object set must be exactly {expected_kinds}, got {kinds}")
# Secret is forbidden HERE, with the shipped full values: the extra-env Secret
# is strictly opt-in. tests/chart.test.sh renders tests/values/extras.yaml and
# asserts the opt-in path separately.
for forbidden in ("Namespace", "Secret", "ServiceAccount", "Role", "RoleBinding", "ClusterRole", "ClusterRoleBinding", "Ingress"):
    check(not by_kind(forbidden), f"the chart must not render a {forbidden}")

minimal_kinds = sorted(doc.get("kind", "?") for doc in minimal_docs)
check("CronJob" not in minimal_kinds, "backup.enabled=false must not render the backup CronJob")
check(
    minimal_kinds.count("PersistentVolumeClaim") == 1,
    f"backup.enabled=false must leave exactly the data PVC, got {minimal_kinds}",
)
check(
    {"Deployment", "Service", "NetworkPolicy"} <= set(minimal_kinds),
    f"backup.enabled=false must still render the workload, got {minimal_kinds}",
)

for doc in docs:
    namespace = (doc.get("metadata") or {}).get("namespace")
    check(namespace in (None, NAMESPACE), f"{doc.get('kind')} pins the wrong namespace: {namespace}")

# The text scans below run over a scrubbed copy of the render. Two things are
# legitimately noise here and would otherwise be false positives:
#   * the nginx ConfigMap's large payloads (nginx.conf and the export bridge,
#     which contains the JS flag __OD_EXPORT_BRIDGE_INSTALLED__) — validate.py
#     inspects those two files directly instead
#   * checksum/* pod annotations, which are legitimately 64 hex characters
def scrub(node):
    if isinstance(node, dict):
        return {
            key: ("<sum>" if str(key).startswith("checksum/") else scrub(value))
            for key, value in node.items()
        }
    if isinstance(node, list):
        return [scrub(item) for item in node]
    return node


scan_docs = []
for doc in docs:
    clone = scrub(copy.deepcopy(doc))
    if clone.get("kind") == "ConfigMap":
        clone["data"] = {
            key: (value if len(str(value)) <= 400 else "<payload omitted>")
            for key, value in (clone.get("data") or {}).items()
        }
    scan_docs.append(clone)
scan_text = yaml.safe_dump_all(scan_docs)

# No unsubstituted placeholder of the class that broke the old chart.
placeholder = re.search(r"__[A-Z0-9_]+__", scan_text)
check(placeholder is None, f"rendered manifests contain a placeholder token: {placeholder.group(0) if placeholder else ''}")
# No plaintext credential survived into the render. An image digest is the one
# legitimate 64-hex string, so it is removed before the scan.
credential_scan = re.sub(r"sha256:[0-9a-f]{64}", "sha256:<digest>", scan_text)
leaked = re.search(r"\b[0-9a-f]{64}\b", credential_scan)
check(leaked is None, f"64-hex secret-shaped literal in the rendered manifests: {leaked.group(0)[:12] + '...' if leaked else ''}")
check(not re.search(r"changeme|(?i:password)\s*:", credential_scan), "plaintext credential in the rendered manifests")
for needle in ("ttyd", "od-mcp", "od-console", "OD_DISABLE_API_AUTH", "OD_API_TOKEN", "pods/exec"):
    check(needle not in scan_text, f"withdrawn component leaked into the render: {needle}")

# --------------------------------------------------------------------- PVCs
for pvc in by_kind("PersistentVolumeClaim"):
    name = pvc["metadata"]["name"]
    spec = pvc.get("spec") or {}
    storage_class = spec.get("storageClassName")
    # The cluster has TWO default StorageClasses (local-path and longhorn), so
    # an omitted storageClassName is resolved by an ambiguous tiebreak.
    check(storage_class == "longhorn", f"PVC {name} must set storageClassName: longhorn explicitly, got {storage_class!r}")
    check(spec.get("accessModes") == ["ReadWriteOnce"], f"PVC {name} must be RWO")
    annotations = (pvc["metadata"].get("annotations") or {})
    check(annotations.get("helm.sh/resource-policy") == "keep", f"PVC {name} must be annotated helm.sh/resource-policy: keep")

# ---------------------------------------------------------------- Deployment
deployment = one("Deployment")
spec = (deployment.get("spec") or {})
pod_spec = ((spec.get("template") or {}).get("spec") or {})
check(spec.get("replicas") == 1, "Deployment must run a single replica (RWO volume)")
check((spec.get("strategy") or {}).get("type") == "Recreate", "Deployment strategy must be Recreate for the RWO Longhorn volume")
check(pod_spec.get("automountServiceAccountToken") is False, "automountServiceAccountToken must be false")
check("serviceAccountName" not in pod_spec, "the chart must not name a ServiceAccount; there is no RBAC")
check(not pod_spec.get("nodeSelector"), "nothing is node-pinned; Longhorn is distributed")
check(pod_spec.get("terminationGracePeriodSeconds") == 60, "terminationGracePeriodSeconds must be 60")

containers = {c.get("name"): c for c in pod_spec.get("containers", [])}
check(set(containers) == {"opendesign", "nginx"}, f"pod must hold exactly the opendesign and nginx containers, got {sorted(containers)}")

annotations = ((spec.get("template") or {}).get("metadata") or {}).get("annotations") or {}
check(any(key.startswith("checksum/") for key in annotations), "pod must carry a checksum/ annotation so a ConfigMap edit rolls it")

od = containers.get("opendesign", {})
image = od.get("image", "")
check(image.startswith("ghcr.io/woowtech/woow-k3s-opendesign"), f"OD image must come from GHCR, got {image!r}")
check("@sha256:" in image, f"the full-values render must pin the image by digest, got {image!r}")
check(not image.endswith(":latest") and "localhost/" not in image, f"forbidden image reference: {image!r}")
check(od.get("imagePullPolicy") != "Never", "imagePullPolicy: Never cannot work on a real cluster")
check(not od.get("ports"), "the daemon is loopback-bound; it must declare no containerPort")
check(not od.get("livenessProbe") and not od.get("readinessProbe"), "the loopback daemon must not carry pod-network probes")
od_security = od.get("securityContext") or {}
check(od_security.get("runAsUser") == 0, "PID 1 must be root to chown the root-owned Longhorn mount")
check(od_security.get("allowPrivilegeEscalation") is False, "allowPrivilegeEscalation must be false")
check((od_security.get("capabilities") or {}).get("drop") == ["ALL"], "all capabilities must be dropped before re-adding the chown set")
# CHOWN/DAC_OVERRIDE/FOWNER/SETUID/SETGID: what prepare_owned_dir + su-exec need.
# KILL: tini runs as PID 1 uid 0 and execs the daemon as uid 1001, and the kernel
# requires CAP_KILL for a cross-uid signal. Without it SIGTERM is never delivered,
# every stop burns the full grace period and ends in SIGKILL with the SQLite WAL
# uncheckpointed. Exact-set, so nothing broader creeps in.
check(set((od_security.get("capabilities") or {}).get("add") or []) == {"CHOWN", "DAC_OVERRIDE", "FOWNER", "SETUID", "SETGID", "KILL"},
      "OD must re-add exactly the capability set prepare_owned_dir + cross-uid SIGTERM need")
od_mounts = {m.get("mountPath") for m in od.get("volumeMounts", [])}
check("/data/opendesign" in od_mounts, "the data PVC must mount at OD_DATA_DIR")
env_from = [list(item.values())[0].get("name") for item in od.get("envFrom", []) if item]
check(any(name and name.endswith("-config") for name in env_from), "OD must take its env from the config ConfigMap")

sidecar = containers.get("nginx", {})
check(sidecar.get("image", "").startswith("nginx:1.27"), f"sidecar must be nginx:1.27-alpine, got {sidecar.get('image')!r}")
sidecar_ports = [p.get("containerPort") for p in sidecar.get("ports", [])]
check(sidecar_ports == [NGINX_PORT], f"sidecar must expose only {NGINX_PORT}, got {sidecar_ports}")
check(DAEMON_PORT not in sidecar_ports, "the daemon port must never appear on the pod network")
sidecar_security = sidecar.get("securityContext") or {}
check(sidecar_security.get("runAsUser") == 101 and sidecar_security.get("runAsGroup") == 101, "sidecar must run as nginx UID/GID 101")
check(sidecar_security.get("readOnlyRootFilesystem") is True, "sidecar root filesystem must be read-only")
check(sidecar_security.get("allowPrivilegeEscalation") is False, "sidecar allowPrivilegeEscalation must be false")
check((sidecar_security.get("capabilities") or {}).get("drop") == ["ALL"], "sidecar must drop all capabilities")
for probe in ("startupProbe", "readinessProbe", "livenessProbe"):
    definition = sidecar.get(probe) or {}
    http_get = definition.get("httpGet") or {}
    check(bool(definition), f"sidecar must carry a {probe}")
    check(http_get.get("path") == "/api/health", f"{probe} must hit /api/health (OD exempts health from origin validation)")
    check(http_get.get("port") in (NGINX_PORT, "http"), f"{probe} must probe the sidecar port, got {http_get.get('port')!r}")
startup = sidecar.get("startupProbe") or {}
check(startup.get("failureThreshold", 0) >= 60, "startupProbe must tolerate a slow Chromium/Longhorn cold start")
sidecar_mounts = {m.get("mountPath") for m in sidecar.get("volumeMounts", [])}
check("/tmp" in sidecar_mounts, "the read-only sidecar needs a writable emptyDir at /tmp")

# The pod-identity label is release-derived (app: <fullname>), exactly as the live
# pi-agent fleet does it (app: pi-agent / app: pi-agent-2). Read it back from the
# Deployment's own pod template so these assertions hold for ANY release name, and
# assert every other object agrees with that single source of truth.
POD_LABELS = ((deployment.get("spec") or {}).get("template") or {}).get("metadata", {}).get("labels") or {}
APP_LABEL = POD_LABELS.get("app")
check(bool(APP_LABEL), "the pod template must carry a non-empty `app` label")
check(((deployment.get("spec") or {}).get("selector") or {}).get("matchLabels", {}).get("app") == APP_LABEL,
      "the Deployment selector must agree with its own pod label")

# tini runs as PID 1 uid 0 and execs the daemon as uid 1001 via su-exec. Without
# CAP_KILL the kernel refuses that cross-uid signal, so SIGTERM is never delivered
# and every stop ends in SIGKILL with the SQLite WAL uncheckpointed.
_od_ctr = [c for c in ((deployment.get("spec") or {}).get("template") or {}).get("spec", {}).get("containers", [])
           if c.get("name") != "nginx"]
check(bool(_od_ctr) and "KILL" in ((_od_ctr[0].get("securityContext") or {}).get("capabilities") or {}).get("add", []),
      "the opendesign container needs CAP_KILL so tini can signal the su-exec'd uid-1001 child")

# ------------------------------------------------------------------- Service
service = one("Service")
service_spec = service.get("spec") or {}
check(service_spec.get("type", "ClusterIP") == "ClusterIP", "the Service must be ClusterIP; NPM is the only ingress path")
ports = service_spec.get("ports") or []
check(len(ports) == 1 and ports[0].get("port") == NGINX_PORT, f"the Service must expose only {NGINX_PORT}, got {ports}")
check(all("nodePort" not in port for port in ports), "a NodePort would bypass the NPM auth boundary")
check((service_spec.get("selector") or {}).get("app") == APP_LABEL, "the Service selector must match the pod label")

# ------------------------------------------------------------- NetworkPolicy
policy = one("NetworkPolicy")
policy_spec = policy.get("spec") or {}
check(sorted(policy_spec.get("policyTypes") or []) == ["Egress", "Ingress"], "the NetworkPolicy must cover both directions")
check((policy_spec.get("podSelector") or {}).get("matchLabels", {}).get("app") == APP_LABEL, "the NetworkPolicy must select the OD pod")
ingress_rules = policy_spec.get("ingress") or []
peers = []
for rule in ingress_rules:
    rule_ports = {port.get("port") for port in (rule.get("ports") or [])}
    check(rule_ports == {NGINX_PORT}, f"every ingress rule must name only port {NGINX_PORT}, got {rule_ports}")
    for peer in rule.get("from") or []:
        peers.append(peer)
check({"podSelector": {"matchLabels": {"app": "npm"}}} in peers, "NPM must be the only pod allowed in")
check(any((peer.get("ipBlock") or {}).get("cidr") == "192.168.0.0/16" for peer in peers), "LAN admin access must match the pi-agent fleet")
check(len(peers) == 2, f"exactly two ingress peers (npm + LAN) are allowed, got {peers}")
check(not any("namespaceSelector" in peer and not peer.get("podSelector") for peer in peers), "a bare namespaceSelector re-opens the old permissive rule")

egress_rules = policy_spec.get("egress") or []
dns_rule = [rule for rule in egress_rules if {p.get("port") for p in rule.get("ports") or []} == {53}]
check(len(dns_rule) == 1, "there must be exactly one DNS egress rule")
world = [
    peer.get("ipBlock") for rule in egress_rules for peer in rule.get("to") or []
    if (peer.get("ipBlock") or {}).get("cidr") == "0.0.0.0/0"
]
check(len(world) == 1, "there must be exactly one world egress rule")
check(world and world[0].get("except") == EGRESS_EXCEPT, f"the egress except list must match the pi-agent fleet exactly: {EGRESS_EXCEPT}")

# ------------------------------------------------------------------- CronJob
cronjob = one("CronJob")
cron_spec = cronjob.get("spec") or {}
check(cron_spec.get("concurrencyPolicy") == "Forbid", "the backup CronJob must not overlap itself")
job_spec = ((cron_spec.get("jobTemplate") or {}).get("spec") or {})
backup_pod = ((job_spec.get("template") or {}).get("spec") or {})
check(backup_pod.get("restartPolicy") == "OnFailure", "backup Job restartPolicy must be OnFailure")
affinity = ((backup_pod.get("affinity") or {}).get("podAffinity") or {})
required = affinity.get("requiredDuringSchedulingIgnoredDuringExecution")
check(bool(required), "the backup Job MUST have a REQUIRED podAffinity; a Longhorn RWO volume attaches to one node "
                      "and a wrongly-scheduled Job hangs on volume attach")
check(not affinity.get("preferredDuringSchedulingIgnoredDuringExecution"), "a preferred podAffinity is not strong enough here")
if required:
    term = required[0]
    check((term.get("labelSelector") or {}).get("matchLabels", {}).get("app") == APP_LABEL, "backup affinity must target the OD pod")
    check(term.get("topologyKey") == "kubernetes.io/hostname", "backup affinity topologyKey must be the node")
backup_containers = backup_pod.get("containers") or []
check(len(backup_containers) == 1, "the backup Job must run one container")
if backup_containers:
    backup_container = backup_containers[0]
    check(backup_container.get("image") == image, "the backup Job must reuse the already-pinned OD image")
    data_mounts = [m for m in backup_container.get("volumeMounts", []) if m.get("mountPath") == "/data/opendesign"]
    check(bool(data_mounts) and data_mounts[0].get("readOnly") is True, "the backup Job must mount the data PVC read-only")
    backup_security = backup_container.get("securityContext") or {}
    check(backup_security.get("runAsUser") == 1001, "the backup Job must run as the OpenDesign UID")
    check((backup_security.get("capabilities") or {}).get("drop") == ["ALL"], "the backup Job must drop all capabilities")

# ----------------------------------------------------------- helm test hook
# A hook pod that carried the chart's selector labels would be added to the
# Service's EndpointSlice the moment its container was Ready -- and it listens
# on nothing, so a share of live requests would be answered with a connection
# refused for as long as it ran. Asserting the label shape is the only way that
# stays fixed.
hook = one("Pod")
hook_annotations = (hook.get("metadata") or {}).get("annotations") or {}
check(hook_annotations.get("helm.sh/hook") == "test", "the Pod in the render must be the helm test hook")
check(hook_annotations.get("helm.sh/hook-delete-policy") == "before-hook-creation",
      "the test hook must be deleted before it is recreated, or a second `helm test` fails on a name clash")
hook_labels = (hook.get("metadata") or {}).get("labels") or {}
selector = (service.get("spec") or {}).get("selector") or {}
check(selector and not all(hook_labels.get(key) == value for key, value in selector.items()),
      f"the test hook pod matches the Service selector {selector} and would join its EndpointSlice")
deployment_selector = ((deployment.get("spec") or {}).get("selector") or {}).get("matchLabels") or {}
check(deployment_selector and not all(hook_labels.get(key) == value for key, value in deployment_selector.items()),
      "the test hook pod matches the Deployment selector and would be adopted by its ReplicaSet")
hook_spec = hook.get("spec") or {}
check(hook_spec.get("restartPolicy") == "Never", "a test hook must not restart")
check(hook_spec.get("automountServiceAccountToken") is False, "the test hook must not mount a ServiceAccount token")
hook_volumes = {v.get("name"): v for v in hook_spec.get("volumes") or []}
check(set(hook_volumes) <= {"tmp"},
      f"the test hook must mount nothing but its own emptyDir, got {sorted(hook_volumes)}")
check("emptyDir" in (hook_volumes.get("tmp") or {}),
      "the test hook's /tmp must be an emptyDir, never a PVC")
for volume in hook_spec.get("volumes") or []:
    check("persistentVolumeClaim" not in volume,
          "the test hook must never mount a PVC; it is a read-only probe")
hook_containers = hook_spec.get("containers") or []
check(len(hook_containers) == 1, "the test hook must run one container")
if hook_containers:
    probe = hook_containers[0]
    check(probe.get("image") == image, "the test hook must reuse the already-pinned OD image, not pull a new one")
    check({m.get("mountPath") for m in probe.get("volumeMounts") or []} <= {"/tmp"},
          "the test hook may mount nothing but its own writable /tmp")
    probe_security = probe.get("securityContext") or {}
    check(probe_security.get("runAsUser") == 1001 and probe_security.get("runAsNonRoot") is True,
          "the test hook must run unprivileged")
    check(probe_security.get("readOnlyRootFilesystem") is True, "the test hook needs no writable filesystem")
    check((probe_security.get("capabilities") or {}).get("drop") == ["ALL"], "the test hook must drop all capabilities")
    command = " ".join(probe.get("command") or [])
    check("/api/health" in command and "/api/version" in command,
          "the test hook must probe /api/health and /api/version")
    for write in ("--post-data", "--method=POST", "-O ", "DELETE", "PUT"):
        check(write not in command, f"the test hook must stay read-only; found {write!r} in its command")

# --------------------------------------------------------------- config env
config_maps = {doc["metadata"]["name"]: doc for doc in by_kind("ConfigMap")}
config = next((doc for name, doc in config_maps.items() if name.endswith("-config")), None)
check(config is not None, "a <release>-config ConfigMap must exist")
if config:
    data = config.get("data") or {}
    check(data.get("OD_BIND_HOST") == "127.0.0.1", "OD_BIND_HOST must be loopback so OD's own token safety floor is honoured")
    check(str(data.get("OD_PORT")) == str(DAEMON_PORT), f"OD_PORT must be {DAEMON_PORT}")
    check(data.get("OD_DATA_DIR") == "/data/opendesign", "OD_DATA_DIR must match the PVC mount")
    check(data.get("OD_ALLOWED_ORIGINS", "").startswith("https://"), "OD_ALLOWED_ORIGINS must be the single https public origin")
    check("*" not in data.get("OD_ALLOWED_ORIGINS", ""), "OD_ALLOWED_ORIGINS must never be a wildcard")
    check(data.get("OD_PUBLIC_BASE_URL") == data.get("OD_ALLOWED_ORIGINS"), "OD_PUBLIC_BASE_URL must be the same public origin")
    check("OD_API_TOKEN" not in data and "OD_DISABLE_API_AUTH" not in data, "neither the token nor the disabled-auth switch may be set")

if errors:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    print(f"\n{len(errors)} rendered-manifest failure(s).", file=sys.stderr)
    sys.exit(1)
print(f"chart manifest assertions: OK ({len(docs)} objects, {len(minimal_docs)} without backup)")
