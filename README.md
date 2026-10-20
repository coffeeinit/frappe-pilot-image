# Frappe Pilot Docker Image

This repository packages the official [Frappe Pilot](https://github.com/frappe/pilot) installer in a systemd-enabled container. It keeps the proven multi-bench model from `compose.yaml`: one persistent Pilot container manages many benches through Pilot's own Admin UI.

The image uses the official released Pilot installer, not `--dev`. That avoids compiling the Admin UI during every build. GitHub Actions checks the official Pilot releases every 24 hours and publishes a new release-tagged image plus `latest` to GHCR only when a new release exists.

Ubuntu 24.04 is retained deliberately because it is supported by the official Pilot installer and matches the known-good local Compose setup. Build speed comes from using the prebuilt Pilot release, BuildKit cache, and GHCR layer cache rather than changing to an unverified base distribution.

## Local build

```bash
docker compose build
docker compose up -d
docker compose logs -f pilot
```

The persistent volume is `pilot_benches`, mounted at `/home/frappe/pilot/benches`. The Pilot Admin UI is available on `http://127.0.0.1:8002` after the container is ready.

## Use the GHCR image

After the GitHub Actions workflow publishes the package, set the image explicitly:

```bash
export PILOT_IMAGE=ghcr.io/YOUR_GITHUB_OWNER/frappe-pilot:latest
docker login ghcr.io
docker compose pull
docker compose up -d
```

If the package is private, the host must authenticate to GHCR. The workflow uses the repository's `GITHUB_TOKEN` and requires the repository Actions permission to write packages.

## Daily update flow

The scheduled workflow runs daily. It reads the latest official Pilot release from GitHub, checks whether the matching release tag already exists in GHCR, and builds only when that tag is missing. The Dockerfile verifies the installed `/home/frappe/pilot/VERSION` matches the release selected by the workflow.

Manual rebuilds are available through **Actions → Build and publish Pilot image → Run workflow**.

## Important runtime requirements

This image intentionally follows Pilot's systemd runtime model:

- `privileged: true`
- host cgroup access
- `/sys/fs/cgroup` mounted read-write
- `/run` and `/run/lock` tmpfs mounts
- `SIGRTMIN+3` stop signal
- persistent `/home/frappe/pilot/benches`

Do not remove these settings unless you also change the Pilot process-manager architecture.
