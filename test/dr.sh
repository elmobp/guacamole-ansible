#!/usr/bin/env bash
# BCP/DR test: build Guacamole on host A, take a backup, restore it onto a fresh
# host B, and confirm guacadmin can still log in on B.
#   test/dr.sh [tag]        (default: ol9)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-ol9}"
source "${REPO_ROOT}/test/run.sh" >/dev/null 2>&1 || true   # reuse base_image/ensure_systemd_image if sourced

case "$TAG" in
  ol9) IMAGE=oraclelinux:9 ;;
  ol10) IMAGE=oraclelinux:10 ;;
  *) echo "dr.sh currently supports ol9|ol10"; exit 2 ;;
esac

A=guac-dr-a; B=guac-dr-b
cleanup() { [[ "${KEEP:-0}" == 1 ]] || podman rm -f "$A" "$B" >/dev/null 2>&1 || true; }
trap cleanup EXIT

boot() {
  local ctr="$1"
  podman rm -f "$ctr" >/dev/null 2>&1 || true
  podman run -d --name "$ctr" --systemd=always --privileged --hostname "${ctr}.guac.local" \
    -v "${REPO_ROOT}:/opt/guac-ansible:ro,Z" "$IMAGE" /sbin/init
  for _ in $(seq 1 30); do
    s=$(podman exec "$ctr" systemctl is-system-running 2>/dev/null || true)
    [[ "$s" == running || "$s" == degraded ]] && break; sleep 2
  done
  podman exec "$ctr" bash -lc '
    dnf -y install "oracle-epel-release-el$(rpm -E %rhel)" >/dev/null 2>&1 || \
      dnf -y install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm" >/dev/null
    dnf -y install ansible >/dev/null 2>&1 || { dnf -y install ansible-core >/dev/null; cd /opt/guac-ansible && ansible-galaxy collection install -r requirements.yml >/dev/null; }
    mkdir -p /root/guac && cp -a /opt/guac-ansible/. /root/guac/'
}

echo "== host A: full build =="
boot "$A"
podman exec "$A" bash -lc 'cd /root/guac && ansible-playbook site.yml'
echo "== host A: create a marker connection + backup =="
podman exec "$A" bash -lc '
  TOKEN=$(curl -sk -d "username=guacadmin&password=guacadmin" https://127.0.0.1/api/tokens | sed "s/.*\"authToken\":\"\([^\"]*\)\".*/\1/")
  curl -sk -X POST "https://127.0.0.1/api/session/data/mysql/connections?token=$TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"parentIdentifier\":\"ROOT\",\"name\":\"DR-TEST-CONN\",\"protocol\":\"ssh\",\"parameters\":{\"hostname\":\"1.2.3.4\",\"port\":\"22\"},\"attributes\":{}}" >/dev/null
  /usr/local/sbin/guac-backup --out /root/bundles
  ls -la /root/bundles'
podman cp "$A:/root/bundles" "/tmp/guac-dr-bundles"
BUNDLE=$(ls -1 /tmp/guac-dr-bundles/guac-backup-* | head -1)
echo "bundle: $BUNDLE"

echo "== host B: provision then restore =="
boot "$B"
podman exec "$B" bash -lc 'cd /root/guac && ansible-playbook site.yml'
podman cp "$BUNDLE" "$B:/root/restore-bundle.tar.gz"
podman exec "$B" bash -lc '/usr/local/sbin/guac-restore /root/restore-bundle.tar.gz'

echo "== host B: verify restored data =="
podman exec "$B" bash -lc '
  set -e
  TOKEN=$(curl -sk -d "username=guacadmin&password=guacadmin" https://127.0.0.1/api/tokens | sed "s/.*\"authToken\":\"\([^\"]*\)\".*/\1/")
  [ -n "$TOKEN" ] || { echo "FAIL: guacadmin cannot log in on host B"; exit 1; }
  echo "$TOKEN" | grep -q . && echo "PASS: guacadmin logs in on restored host"
  curl -sk "https://127.0.0.1/api/session/data/mysql/connections?token=$TOKEN" | grep -q "DR-TEST-CONN" \
    && echo "PASS: restored connection DR-TEST-CONN present" \
    || { echo "FAIL: restored connection missing"; exit 1; }'
echo "DR TEST PASSED"
