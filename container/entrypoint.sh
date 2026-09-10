#!/usr/bin/env bash
# Runtime process orchestration for the Guacamole appliance image.
# (Orchestration only — install/config was done by the Ansible roles at build time.)
set -euo pipefail

GUAC_HOME="${GUACAMOLE_HOME:-/etc/guacamole}"
TOMCAT_HOME="${CATALINA_HOME:-/opt/tomcat}"
: "${GUACD_BIND_HOST:=127.0.0.1}"
: "${GUACD_BIND_PORT:=4822}"
: "${GUAC_DB_PORT:=3306}"
: "${GUAC_DB_NAME:=guacamole_db}"
: "${GUAC_DB_USER:=guacamole_user}"

JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
export JAVA_HOME CATALINA_HOME="${TOMCAT_HOME}" CATALINA_PID="${TOMCAT_HOME}/temp/tomcat.pid"

if [[ -z "${GUAC_DB_HOST:-}" ]]; then
  echo "[entrypoint] FATAL: set GUAC_DB_HOST (and GUAC_DB_PASSWORD)" >&2; exit 2
fi
: "${GUAC_DB_PASSWORD:?GUAC_DB_PASSWORD is required}"

echo "[entrypoint] waiting for database ${GUAC_DB_HOST}:${GUAC_DB_PORT}"
for _ in $(seq 1 90); do
  if mysql -h "${GUAC_DB_HOST}" -P "${GUAC_DB_PORT}" -u "${GUAC_DB_USER}" \
       -p"${GUAC_DB_PASSWORD}" -e 'SELECT 1' "${GUAC_DB_NAME}" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# First-run schema bootstrap (idempotent: only if the core table is absent)
if ! mysql -h "${GUAC_DB_HOST}" -P "${GUAC_DB_PORT}" -u "${GUAC_DB_USER}" -p"${GUAC_DB_PASSWORD}" \
     -e 'SELECT 1 FROM guacamole_user LIMIT 1' "${GUAC_DB_NAME}" >/dev/null 2>&1; then
  if [[ -n "${GUAC_DB_ADMIN_USER:-}" && -n "${GUAC_DB_ADMIN_PASSWORD:-}" && -f /opt/guac-schema/schema.sql ]]; then
    echo "[entrypoint] importing Guacamole schema into ${GUAC_DB_NAME}"
    mysql -h "${GUAC_DB_HOST}" -P "${GUAC_DB_PORT}" -u "${GUAC_DB_ADMIN_USER}" \
      -p"${GUAC_DB_ADMIN_PASSWORD}" "${GUAC_DB_NAME}" < /opt/guac-schema/schema.sql
  else
    echo "[entrypoint] WARNING: schema not present and no admin creds to load it" >&2
  fi
fi

# Render guacamole.properties from the environment
cat > "${GUAC_HOME}/guacamole.properties" <<EOF
guacd-hostname: ${GUACD_BIND_HOST}
guacd-port: ${GUACD_BIND_PORT}
mysql-hostname: ${GUAC_DB_HOST}
mysql-port: ${GUAC_DB_PORT}
mysql-database: ${GUAC_DB_NAME}
mysql-username: ${GUAC_DB_USER}
mysql-password: ${GUAC_DB_PASSWORD}
EOF

term() { echo "[entrypoint] shutting down"; kill "${pids[@]}" 2>/dev/null || true; }
trap term SIGTERM SIGINT
pids=()

echo "[entrypoint] starting guacd"
/usr/local/sbin/guacd -f -b "${GUACD_BIND_HOST}" -l "${GUACD_BIND_PORT}" &
pids+=($!)

echo "[entrypoint] starting tomcat"
exec "${TOMCAT_HOME}/bin/catalina.sh" run
