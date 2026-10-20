# syntax=docker/dockerfile:1.7
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    container=docker

STOPSIGNAL SIGRTMIN+3

# Pin the digest, not just the tag, for reproducibility.
COPY --from=ghcr.io/astral-sh/uv:0.13.1 /uv /uvx /usr/local/bin/

ARG PILOT_EXPECTED_RELEASE=unknown
# Pin this to the release tag from the workflow, e.g.
# https://raw.githubusercontent.com/frappe/pilot/v15.x.x/install.sh
ARG PILOT_INSTALL_URL=https://raw.githubusercontent.com/frappe/pilot/develop/install.sh

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl systemd systemd-sysv dbus libpam-systemd sudo \
    && rm -rf /var/lib/apt/lists/*

# Root pass. The echo is deliberate: it makes PILOT_EXPECTED_RELEASE part of
# this layer's cache key, so a new release busts the GHA build cache instead
# of silently reusing a stale install layer.
RUN echo "Installing Pilot release: ${PILOT_EXPECTED_RELEASE} from ${PILOT_INSTALL_URL}" \
    && curl -fsSL --proto '=https' --tlsv1.2 "$PILOT_INSTALL_URL" -o /tmp/install-pilot.sh \
    && bash /tmp/install-pilot.sh \
    && rm -f /tmp/install-pilot.sh

# frappe-user pass. uid/gid so the non-root user can write the uv cache mount.
# The echo again keeps the release in this layer's cache key.
RUN --mount=type=cache,target=/tmp/uvcache,uid=1000,gid=1000,sharing=locked \
    su - frappe -c "echo 'Installing Pilot release: ${PILOT_EXPECTED_RELEASE}' \
      && curl -fsSL --proto '=https' --tlsv1.2 '$PILOT_INSTALL_URL' | bash"

# Normalize an optional leading "v" before comparing.
RUN if [ "$PILOT_EXPECTED_RELEASE" != "unknown" ]; then \
      test -f /home/frappe/pilot/VERSION || { echo "VERSION file missing" >&2; exit 1; } ; \
      want="${PILOT_EXPECTED_RELEASE#v}" ; \
      got="$(cat /home/frappe/pilot/VERSION)" ; got="${got#v}" ; \
      if [ "$want" != "$got" ]; then \
        echo "Release mismatch: expected $want, installed $got" >&2 ; exit 1 ; \
      fi ; \
      echo "Verified Pilot release: $got" ; \
    fi

# Pilot owns per-user services; do not leave distro services auto-started.
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
