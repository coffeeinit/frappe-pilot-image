# Frappe Pilot Docker Image

The official [Frappe Pilot](https://github.com/frappe/pilot) installer, packaged in a systemd-enabled container. One persistent container manages many benches through Pilot's own Admin UI.

The image uses the released Pilot installer (not `--dev`), so the Admin UI is downloaded prebuilt instead of compiled on every build. A GitHub Actions workflow checks for new Pilot releases daily and publishes a release-tagged image plus `latest` to GHCR when one appears.

Ubuntu 24.04 is used deliberately — it's supported by the official installer and matches the known-good local Compose setup.

---

## Run

```bash
docker run -d --name pilot \
  --privileged --cgroupns=host \
  --tmpfs /run --tmpfs /run/lock \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v pilot-benches:/home/frappe/pilot/benches \
  -p 8000:8000 -p 8002:8002 -p 9000:9000 -p 7000:7000 \
  ghcr.io/coffeeinit/frappe-pilot:latest

docker volume create pilot-test-fresh

docker run -d --name pilot-test \
  --privileged --cgroupns=host \
  --tmpfs /run --tmpfs /run/lock \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v pilot-test-fresh:/home/frappe/pilot/benches \
  local/frappe-pilot:test
# inside: docker exec -it -u frappe pilot-test bash -lc 'pilot new t && pilot -b t start'


```

Admin UI: `http://127.0.0.1:8002`

---

## Local build

```bash
docker compose build
docker compose up -d
docker compose logs -f pilot
```

Volume: `pilot_benches` → `/home/frappe/pilot/benches`

---

## Use the GHCR image

```bash
export PILOT_IMAGE=ghcr.io/coffeeinit/frappe-pilot:latest
docker login ghcr.io
docker compose pull
docker compose up -d
```

If the package is private, the host must authenticate to GHCR.

---

## Updates

The scheduled workflow runs daily. It reads the latest Pilot release, checks whether that tag already exists in GHCR, and builds only if it's missing.

Manual rebuild: **Actions → Build and publish Pilot image → Run workflow**

---

## Runtime requirements

The image follows Pilot's systemd runtime model. Do not remove these:

- `privileged: true`
- `--cgroupns=host`
- `/sys/fs/cgroup` mounted read-write
- `/run` and `/run/lock` as tmpfs
- `SIGRTMIN+3` stop signal
- persistent `/home/frappe/pilot/benches`

Changing any of them means changing Pilot's process-manager architecture.
