# CI, validation and releases

Everything below runs from the repository itself. There is no hidden step and
no manual gate other than pushing a tag.

## The single local gate

```bash
./tests/run.sh
```

CI runs exactly this script in the `validate` job, so a green local run and a
green CI run mean the same thing. Lanes, in order:

| Lane | What it proves |
|---|---|
| `tests/lib/extract-chart-assets.py` | the chart renders, and the sidecar's `nginx.conf` / export bridge are taken from the rendered ConfigMap rather than guessed from source |
| `tests/validate.py` | chart identity and pinning, no credential-shaped value or 64-hex literal in the chart or in `deploy/`, `.gitignore` patterns anchored, image/runtime pins, launcher and renderer invariants |
| `tests/workflow-policy.test.py` | CI least privilege (`packages: write` only in `publish-release`), every action pinned to a 40-character SHA, releases immutable |
| `tests/chart.test.sh` | `helm lint` and `helm template` for **every** values combination the repo ships, one negative fixture per render-time guard, `kubeconform -strict` over every render, the retention assertions, `kubectl apply --dry-run=server` when a cluster is reachable, `helm package` completeness, and that no file under `chart/` is git-ignored or untracked |
| `node --check`, `bash -n` | syntax of every JS and shell file, the release scripts included |
| `node --test` | the renderer, export-bridge and launcher unit tests |
| `shellcheck`, `nginx -t` | when installed; a skipped one says so loudly |

Nothing in that list needs Docker or a cluster. The container lane
(`tests/container-smoke.sh`) needs podman and a built image and runs in its own
CI job.

## Pinned tooling

`helm`, `kubeconform` and `yq` are downloaded in CI and verified against a
`sha256sum --check --strict` before they are put on `PATH` — see the `env:`
block of `.github/workflows/build.yml`. The versions are Helm **3.19.5** and
kubeconform **0.6.7**. A checksum-pinned tarball is a stronger guarantee than a
setup action pinned by tag, and it keeps the workflow's action list short; the
policy test enforces that every action that *is* used is pinned to a full commit
SHA.

The container base is pinned by digest in `Dockerfile:1` and re-asserted in
`build.yml` (`BUILD_FROM`) and in `tests/validate.py`, so all three must agree.

## Jobs

| Job | Runs on | Does |
|---|---|---|
| `validate` | every push and PR | `./tests/run.sh` |
| `smoke` | every push and PR | builds the amd64 image (`load: true`, `push: false`) and runs the real two-container pod smoke |
| `build-nonrelease` | non-tag refs | builds the image and `helm package`s the chart, publishing neither |
| `release-preflight` | `v*` tags | fails closed unless **both** the image and the OCI chart for this version are provably absent from GHCR |
| `release-architecture-gate` | `v*` tags | boots the release image and proves the OpenCode BYOK path streams and that a fake key reaches neither the logs nor `/data` |
| `publish-release` | `v*` tags | pushes `ghcr.io/woowtech/woow-k3s-opendesign:<version>` and `oci://ghcr.io/woowtech/charts/opendesign:<version>`, then prints the image digest in the job summary |

`publish-release` is the only job with `packages: write`.

## Releasing

1. Land the change on `main`.
2. Bump `chart/Chart.yaml` `version` **and** `CHART_VERSION` in
   `tests/validate.py` — they are asserted equal. `appVersion` is the upstream
   OpenDesign version and moves only when the image's base does.
3. Tag `v<chart version>` and push the tag.
4. Copy the image digest from the job summary into `chart/values.yaml`
   `image.digest`, or into the instance values of each release.

Published versions are **immutable**. Recovering a partial release means
bumping the version and cutting a new tag, never overwriting: the preflight
refuses to publish over an existing artifact.

The chart version is also a pod template label (`helm.sh/chart`), so bumping it
and upgrading a live release rolls the pod once. That is expected; it is called
out in `docs/MIGRATION.md` so it is never a surprise.
