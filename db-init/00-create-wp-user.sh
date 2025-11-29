#!/usr/bin/env bash
set -euo pipefail

# This init script runs inside the MariaDB container at first startup.
# It creates/updates the non-root user with full privileges (DB creation included).

if [[ -z "${MARIADB_ROOT_PASSWORD:-}" ]]; then
  echo "MARIADB_ROOT_PASSWORD is required for init script" >&2
  exit 1
fi

if [[ -n "${MARIADB_USER:-}" && -n "${MARIADB_PASSWORD:-}" ]]; then
  mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" <<SQL
CREATE USER IF NOT EXISTS '${MARIADB_USER}'@'%' IDENTIFIED BY '${MARIADB_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO '${MARIADB_USER}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
fi
