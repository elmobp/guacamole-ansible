#!/usr/bin/env bash
# Upgrade test: install an older Guacamole, then bump guac_version and re-run.
# Confirms guacd rebuilds, war/jars refresh, schema upgrades apply, login still works.
#   test/upgrade.sh [tag] [from_version] [to_version]
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-ol9}"
FROM="${2:-1.5.5}"
TO="${3:-1.6.0}"

case "$TAG" in
  ol9) IMAGE=oraclelinux:9 ;;
  ol10) IMAGE=oraclelinux:10 ;;
  *) echo "upgrade.sh supports ol9|ol10"; exit 2 ;;
esac
CTR=guac-upgrade
cleanup() { [[ "${KEEP:-0}" == 1 ]] || podman rm -f "$CTR" >/dev/null 2>&1 || true; }
trap cleanup EXIT

podman rm -f "$CTR" >/dev/null 2>&1 || true
podman run -d --name "$CTR" --systemd=always --privileged --hostname "${CTR}.guac.local" \
  -v "${REPO_ROOT}:/opt/guac-ansible:ro,Z" "$IMAGE" /sbin/init
for _ in $(seq 1 30); do
  s=$(podman exec "$CTR" systemctl is-system-running 2>/dev/null || true)
  [[ "$s" == running || "$s" == degraded ]] && break; sleep 2
done
podman exec "$CTR" bash -lc '
  dnf -y install "oracle-epel-release-el$(rpm -E %rhel)" >/dev/null 2>&1 || \
    dnf -y install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm" >/dev/null
  dnf -y install ansible >/dev/null 2>&1 || { dnf -y install ansible-core >/dev/null; cd /opt/guac-ansible && ansible-galaxy collection install -r requirements.yml >/dev/null; }
  mkdir -p /root/guac && cp -a /opt/guac-ansible/. /root/guac/'

echo "== install ${FROM} =="
podman exec "$CTR" bash -lc "cd /root/guac && ansible-playbook site.yml -e guac_version=${FROM}"
podman exec "$CTR" bash -lc "cat /etc/guacamole/.guac_schema_version; ls /etc/guacamole/extensions; /usr/local/sbin/guacd -v 2>&1 | head -1"

echo "== upgrade to ${TO} (only the version number changes) =="
podman exec "$CTR" bash -lc "cd /root/guac && ansible-playbook site.yml -e guac_version=${TO}"

echo "== verify =="
podman exec "$CTR" bash -lc "
  set -e
  cd /root/guac
  grep -q '${TO}' /etc/guacamole/.guac_schema_version || { echo 'FAIL: schema marker not ${TO}'; exit 1; }
  /usr/local/sbin/guacd -v 2>&1 | grep -q '${TO}' || { echo 'FAIL: guacd not ${TO}'; exit 1; }
  ls /etc/guacamole/extensions | grep -q \"guacamole-auth-jdbc-mysql-${TO}.jar\" || { echo 'FAIL: jdbc jar not ${TO}'; exit 1; }
  ls /etc/guacamole/extensions | grep -q \"${FROM}\" && { echo 'FAIL: stale ${FROM} jar left behind'; exit 1; } || true
  ls /etc/guacamole/*.war | grep -q \"guacamole-${TO}.war\" || { echo 'FAIL: war not ${TO}'; exit 1; }
  ls /etc/guacamole/ | grep -q \"guacamole-${FROM}.war\" && { echo 'FAIL: stale ${FROM} war left behind'; exit 1; } || true
  bash test/check.sh"
echo "== idempotence at ${TO} =="
podman exec -e ANSIBLE_NOCOLOR=1 "$CTR" bash -lc "cd /root/guac && ansible-playbook site.yml -e guac_version=${TO} | grep -A1 'PLAY RECAP' | grep -q 'changed=0.*failed=0'" \
  && echo 'PASS: idempotent at target version' || echo 'WARN: not fully idempotent (review)'
echo "UPGRADE TEST PASSED"
