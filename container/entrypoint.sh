#!/usr/bin/env bash
# Runtime process orchestration for the Guacamole container image.
# (Orchestration only — all install/config was done by the Ansible roles at build time.)
set -euo pipefail

GUAC_HOME="${GUACAMOLE_HOME:-/etc/guacamole}"
TOMCAT_HOME="${CATALINA_HOME:-/opt/tomcat}"
: "${GUACD_BIND_HOST:=127.0.0.1}"
: "${GUACD_BIND_PORT:=4822}"

# Wait for the database (compose starts MariaDB alongside).
if [[ -n "${GUAC_DB_HOST:-}" ]]; then
  echo "[entrypoint] waiting for database ${GUAC_DB_HOST}:${GUAC_DB_PORT:-3306}"
  for _ in $(seq 1 60); do
    (exec 3<>"/dev/tcp/${GUAC_DB_HOST}/${GUAC_DB_PORT:-3306}") 2>/dev/null && break
    sleep 2
  done
fi

# Regenerate guacamole.properties from env if provided (compose supplies DB creds).
if [[ -n "${GUAC_DB_HOST:-}" ]]; then
  cat > "${GUAC_HOME}/guacamole.properties" <<EOF
guacd-hostname: ${GUACD_BIND_HOST}
guacd-port: ${GUACD_BIND_PORT}
mysql-hostname: ${GUAC_DB_HOST}
mysql-port: ${GUAC_DB_PORT:-3306}
mysql-database: ${GUAC_DB_NAME:-guacamole_db}
mysql-username: ${GUAC_DB_USER:-guacamole_user}
mysql-password: ${GUAC_DB_PASSWORD:?GUAC_DB_PASSWORD is required}
EOF
fi

term() { echo "[entrypoint] shutting down"; kill "${pids[@]}" 2>/dev/null || true; }
trap term SIGTERM SIGINT

pids=()
echo "[entrypoint] starting guacd"
/usr/local/sbin/guacd -f -b "${GUACD_BIND_HOST}" -l "${GUACD_BIND_PORT}" &
pids+=($!)

if [[ "${GUAC_ENABLE_NGINX:-true}" == "true" && -x /usr/sbin/nginx ]]; then
  echo "[entrypoint] starting nginx"
  nginx -g 'daemon off;' &
  pids+=($!)
fi

echo "[entrypoint] starting tomcat"
export JAVA_HOME CATALINA_HOME="${TOMCAT_HOME}" CATALINA_PID="${TOMCAT_HOME}/temp/tomcat.pid"
exec "${TOMCAT_HOME}/bin/catalina.sh" run
