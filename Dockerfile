# syntax=docker/dockerfile:1.7
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    container=docker

STOPSIGNAL SIGRTMIN+3

# uv is used by the official Pilot installer. BuildKit keeps apt and uv caches
# outside the image while reusing them across GitHub Actions builds.
COPY --from=ghcr.io/astral-sh/uv:0.13.1 /uv /uvx /usr/local/bin/

RUN rm -f /etc/apt/apt.conf.d/docker-clean
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl systemd systemd-sysv dbus libpam-systemd sudo \
    && rm -rf /var/lib/apt/lists/*

# Official Pilot installation, root pass. This prepares Ubuntu, creates the
# frappe user, installs database/runtime dependencies, and enables linger.
ARG PILOT_INSTALL_URL=https://raw.githubusercontent.com/frappe/pilot/develop/install.sh
ARG PILOT_EXPECTED_RELEASE=unknown
RUN curl -fsSL --proto '=https' --tlsv1.2 "$PILOT_INSTALL_URL" -o /tmp/install-pilot.sh \
    && sh /tmp/install-pilot.sh \
    && rm -f /tmp/install-pilot.sh

# Official Pilot installation, frappe-user pass. No --dev flag is used, so the
# installer downloads the released prebuilt Admin UI instead of compiling it.
RUN --mount=type=cache,target=/tmp/uvcache,sharing=locked \
    su - frappe -c "curl -fsSL --proto '=https' --tlsv1.2 '$PILOT_INSTALL_URL' | UV_CACHE_DIR=/tmp/uvcache UV_LINK_MODE=copy UV_HTTP_TIMEOUT=300 UV_HTTP_RETRIES=10 sh"

# Refuse to publish an image whose installed release differs from the release
# selected by the scheduled GitHub workflow. Local builds may leave this unset.
RUN if [ "$PILOT_EXPECTED_RELEASE" != "unknown" ]; then \
      test -f /home/frappe/pilot/VERSION \
      && test "$(cat /home/frappe/pilot/VERSION)" = "$PILOT_EXPECTED_RELEASE"; \
    fi

# Pilot owns per-user services; do not leave distro services auto-started.
RUN systemctl disable mariadb postgresql redis-server nginx supervisor 2>/dev/null || true \
    && mkdir -p /var/lib/systemd/linger /home/frappe/pilot/benches \
    && touch /var/lib/systemd/linger/frappe \
    && chown -R frappe:frappe /home/frappe/pilot

LABEL org.opencontainers.image.title="Frappe Pilot" \
      org.opencontainers.image.description="Official Frappe Pilot runtime in a systemd-enabled container" \
      org.opencontainers.image.source="https://github.com/frappe/pilot"

VOLUME ["/home/frappe/pilot/benches"]
EXPOSE 8002 8000 9000 7000

CMD ["/sbin/init"]
