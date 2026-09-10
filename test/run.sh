#!/usr/bin/env bash
# =============================================================================
# Test orchestration ONLY — this script provisions a throwaway systemd container
# and runs the Ansible playbook *inside* it. It performs no install logic itself;
# everything that builds Guacamole lives in the Ansible roles.
#
#   test/run.sh ol9      # Oracle Linux 9  (RHEL 9 family)
#   test/run.sh ol10     # Oracle Linux 10 (RHEL 10 family)
#   test/run.sh both     # run both, sequentially
#   KEEP=1 test/run.sh ol9   # leave the container running afterwards
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-both}"
KEEP="${KEEP:-0}"

run_one() {
  local tag="$1" image ctr
  case "$tag" in
    ol9)  image="oraclelinux:9";  ctr="guac-test-ol9" ;;
    ol10) image="oraclelinux:10"; ctr="guac-test-ol10" ;;
    *) echo "unknown target: $tag (use ol9|ol10|both)" >&2; exit 2 ;;
  esac

  echo "=============================================================="
  echo ">>> $tag :: $image"
  echo "=============================================================="

  podman rm -f "$ctr" >/dev/null 2>&1 || true
  podman run -d --name "$ctr" --systemd=always --privileged \
    --hostname "guac-${tag}.guac.local" \
    -v "${REPO_ROOT}:/opt/guac-ansible:ro,Z" \
    "$image" /sbin/init

  # Wait for systemd to be ready
  for _ in $(seq 1 30); do
    if podman exec "$ctr" systemctl is-system-running --wait >/dev/null 2>&1; then break; fi
    sleep 2
  done

  # Bootstrap Ansible (control tooling only — not part of the product)
  podman exec "$ctr" bash -lc '
    set -e
    dnf -y install python3 python3-pip >/dev/null
    python3 -m pip install --quiet --upgrade pip
    python3 -m pip install --quiet "ansible-core>=2.16"
    mkdir -p /root/guac && cp -a /opt/guac-ansible/. /root/guac/
    cd /root/guac
    ansible-galaxy collection install -r requirements.yml >/dev/null
  '

  # First run
  podman exec "$ctr" bash -lc 'cd /root/guac && ansible-playbook site.yml'

  # Idempotence run — assert zero changed
  echo ">>> $tag :: idempotence check"
  podman exec "$ctr" bash -lc '
    cd /root/guac
    out=$(ansible-playbook site.yml 2>&1)
    echo "$out" | tail -n 20
    echo "$out" | grep -Eq "changed=0 .*failed=0" || { echo "IDEMPOTENCE FAILED ($tag)"; exit 1; }
  '

  # Functional checks
  podman exec "$ctr" bash -lc 'cd /root/guac && bash test/check.sh'

  echo ">>> $tag :: PASS"
  if [[ "$KEEP" != "1" ]]; then podman rm -f "$ctr" >/dev/null; fi
}

case "$TARGET" in
  both) run_one ol9; run_one ol10 ;;
  *)    run_one "$TARGET" ;;
esac

echo
echo "ALL TARGETS PASSED"
