#!/bin/bash
set -euo pipefail

MARIADB_BASE=/home/frappe/pilot/databases/mariadb

# Only bootstrap once, and only if Pilot hasn't already provisioned it.
if [ -d "$MARIADB_BASE" ] && [ -d "$MARIADB_BASE/data/mysql" ] && \
   [ ! -f "$MARIADB_BASE/.bootstrapped" ]; then
    MARIADB_SOCK="$MARIADB_BASE/run/mysqld.sock"
    mkdir -p "$MARIADB_BASE/run"
    chown -R frappe:frappe "$MARIADB_BASE"

    su - frappe -c "mariadbd-safe \
        --datadir=$MARIADB_BASE/data \
        --socket=$MARIADB_SOCK" &

    for i in $(seq 1 60); do
        su - frappe -c "mariadb --socket=$MARIADB_SOCK -u root -e 'SELECT 1'" \
            >/dev/null 2>&1 && break
        sleep 1
    done

    su - frappe -c "mariadb --socket=$MARIADB_SOCK -u root" <<'SQL'
CREATE USER IF NOT EXISTS 'frappe'@'localhost' IDENTIFIED VIA unix_socket;
GRANT ALL PRIVILEGES ON *.* TO 'frappe'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

    su - frappe -c "mariadb-admin --socket=$MARIADB_SOCK -u root shutdown" || true
    touch "$MARIADB_BASE/.bootstrapped"
    chown frappe:frappe "$MARIADB_BASE/.bootstrapped"
fi

exec /sbin/init
