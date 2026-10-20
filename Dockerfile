# syntax=docker/dockerfile:1.7
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    container=docker

STOPSIGNAL SIGRTMIN+3

# uv is used by the official Pilot installer. BuildKit keeps apt and uv caches
# outside the image while reusing them across GitHub Actions builds.
COPY --from=ghcr.io/astral-sh/uv:0.13.1 /uv /uvx /usr/local/bin/

# Build-args. PILOT_EXPECTED_RELEASE and PILOT_INSTALL_URL are both supplied by
# the workflow; local builds may leave them at their defaults.
ARG PILOT_EXPECTED_RELEASE=unknown
ARG PILOT_INSTALL_URL=https://raw.githubusercontent.com/frappe/pilot/develop/install.sh

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl systemd systemd-sysv dbus libpam-systemd sudo \
    && rm -rf /var/lib/apt/lists/*

# Official Pilot installation, root pass. This prepares Ubuntu, creates the
# frappe user, installs database/runtime dependencies, and enables linger.
# The echo is deliberate: it makes PILOT_EXPECTED_RELEASE part of this layer's
# cache key, so a new release busts the GHA build cache instead of silently
# reusing a stale install layer.
RUN echo "Installing Pilot release: ${PILOT_EXPECTED_RELEASE} from ${PILOT_INSTALL_URL}" \
    && curl -fsSL --proto '=https' --tlsv1.2 "$PILOT_INSTALL_URL" -o /tmp/install-pilot.sh \
    && bash /tmp/install-pilot.sh \
    && rm -f /tmp/install-pilot.sh

# Official Pilot installation, frappe-user pass. No --dev flag is used, so the
# installer downloads the released prebuilt Admin UI instead of compiling it.
# The chown is required: BuildKit creates cache mounts root-owned, and the
# frappe user cannot create uv's lock/tmp files without write access. The echo
# again keeps the release in this layer's cache key.
RUN --mount=type=cache,target=/tmp/uvcache,sharing=locked \
    chown "$(id -u frappe):$(id -g frappe)" /tmp/uvcache \
    && su - frappe -c "echo 'Installing Pilot release: ${PILOT_EXPECTED_RELEASE}' \
      && curl -fsSL --proto '=https' --tlsv1.2 '${PILOT_INSTALL_URL}' \
         | UV_CACHE_DIR=/tmp/uvcache UV_LINK_MODE=copy UV_HTTP_TIMEOUT=300 UV_HTTP_RETRIES=10 bash"

# Refuse to publish an image whose installed release differs from the release
# selected by the scheduled GitHub workflow. A leading "v" is normalized away
# on both sides so tags like v15.2.0 match VERSION files containing 15.2.0.
# Local builds may leave PILOT_EXPECTED_RELEASE unset ("unknown").
RUN if [ "$PILOT_EXPECTED_RELEASE" != "unknown" ]; then \
      test -f /home/frappe/pilot/VERSION || { echo "VERSION file missing" >&2; exit 1; } ; \
      want="${PILOT_EXPECTED_RELEASE#v}" ; \
      got="$(cat /home/frappe/pilot/VERSION)" ; got="${got#v}" ; \
      if [ "$want" != "$got" ]; then \
        echo "Release mismatch: expected $want, installed $got" >&2 ; exit 1 ; \
      fi ; \
      echo "Verified Pilot release: $got" ; \
    fi

# Bootstrap MariaDB. install.sh installs MariaDB but never creates a
# 'frappe'@'localhost' account, and modern MariaDB puts root on unix_socket
# auth, so `pilot init` fails at secure_installation() with
#   ERROR 1698 (28000): Access denied for user 'frappe'@'localhost'
# on a fresh volume. Pre-provision the account here so a container started on
# a brand-new volume can complete `pilot start` without manual DB surgery.
#
# Guarded: if a future install.sh lays MariaDB out elsewhere, this step is
# skipped instead of failing the build. If the datadir is missing entirely,
# mariadb-install-db creates one that matches root-on-socket semantics.
RUN set -eux; \
    MARIADB_BASE=/home/frappe/pilot/databases/mariadb; \
    if [ -d "$MARIADB_BASE" ]; then \
        MARIADB_DATA="$MARIADB_BASE/data"; \
        MARIADB_RUN="$MARIADB_BASE/run"; \
        MARIADB_SOCK="$MARIADB_RUN/mysqld.sock"; \
        mkdir -p "$MARIADB_RUN"; \
        chown -R frappe:frappe "$MARIADB_BASE"; \
        if [ ! -d "$MARIADB_DATA/mysql" ]; then \
            mariadb-install-db \
                --user=frappe \
                --datadir="$MARIADB_DATA" \
                --auth-root-authentication-method=socket; \
        fi; \
        mariadbd-safe --user=frappe --datadir="$MARIADB_DATA" --socket="$MARIADB_SOCK" & \
        MARIADB_PID=$!; \
        READY=0; \
        for i in $(seq 1 60); do \
            if mariadb --socket="$MARIADB_SOCK" -u root -e "SELECT 1" >/dev/null 2>&1; then \
                READY=1; break; \
            fi; \
            sleep 1; \
        done; \
        if [ "$READY" != "1" ]; then \
            echo "MariaDB did not become ready within 60s" >&2; \
            cat "$MARIADB_BASE"/*.err 2>/dev/null || true; \
            exit 1; \
        fi; \
        mariadb --socket="$MARIADB_SOCK" -u root <<-SQL
            CREATE USER IF NOT EXISTS 'frappe'@'localhost' IDENTIFIED VIA unix_socket;
            GRANT ALL PRIVILEGES ON *.* TO 'frappe'@'localhost' WITH GRANT OPTION;
            FLUSH PRIVILEGES;
        SQL
        mariadb-admin --socket="$MARIADB_SOCK" -u root shutdown || true; \
        wait "$MARIADB_PID" 2>/dev/null || true; \
        chown -R frappe:frappe "$MARIADB_BASE"; \
    else \
        echo "note: ${MARIADB_BASE} not present at build time; skipping MariaDB bootstrap"; \
    fi

# Pilot owns per-user services; do not leave distro services auto-started.
# Log rather than silently swallow failures, and tolerate units that were
# never installed.
RUN for svc in mariadb postgresql redis-server nginx supervisor; do \
      systemctl disable "$svc" || echo "note: $svc not present, skipping" ; \
    done \
    && mkdir -p /var/lib/systemd/linger /home/frappe/pilot/benches \
    && touch /var/lib/systemd/linger/frappe \
    && chown -R frappe:frappe /home/frappe/pilot

LABEL org.opencontainers.image.title="Frappe Pilot" \
      org.opencontainers.image.description="Official Frappe Pilot runtime in a systemd-enabled container" \
      org.opencontainers.image.source="https://github.com/frappe/pilot"

VOLUME ["/home/frappe/pilot/benches"]
EXPOSE 8002 8000 9000 7000

CMD ["/sbin/init"]
