# Locked OpenCode runtime

This directory packages the official [OpenCode](https://github.com/anomalyco/opencode)
npm distribution, [`opencode-ai`](https://www.npmjs.com/package/opencode-ai), at version
`1.18.29`. It is MIT licensed. `package-lock.json` commits npm registry tarball integrity
hashes for the launcher and the Linux musl `x64` and `arm64` binaries used by the Alpine
image. The Docker build runs `npm ci` from this lockfile into
`/opt/woow-opendesign/opencode`; its `.bin` directory is on `PATH`.

OpenCode is the BYOK (bring-your-own-key) agent runtime that OpenDesign's native
`byok-opencode` provider shells out to. No provider API key is baked into the image,
stored in a ConfigMap or Secret, or passed as an environment variable: keys are entered
in the browser and held browser-locally.

OpenCode is the only agent CLI in this image. Every other agent runtime -- including the
one the upstream add-on withdrew -- is deliberately absent and is fenced out by
`tests/validate.py`, `tests/container-smoke.sh` and the release workflow. Do not
reintroduce one here.
