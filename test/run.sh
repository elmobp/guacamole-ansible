#!/usr/bin/env bash
# =============================================================================
# Test orchestration ONLY — provisions throwaway systemd containers and runs the
# Ansible playbook *inside* each one. No install logic lives here; everything
# that builds Guacamole is in the roles.
#
#   test/run.sh                     # full matrix
#   test/run.sh ol9 debian12        # a subset
#   test/run.sh all                 # full matrix (explicit)
#   KEEP=1 test/run.sh ol9          # leave the container running afterwards
#
# Matrix tags: ol9 ol10 debian12 debian13 ubuntu2204 ubuntu2404
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP="${KEEP:-0}"
ALL_TAGS=(ol9 ol10 debian12 debian13 ubuntu2204 ubuntu2404)

[[ $# -eq 0 || "${1:-}" == "all" ]] && TAGS=("${ALL_TAGS[@]}") || TAGS=("$@")

base_image() {
  case "$1" in
    ol9)        echo "oraclelinux:9" ;;
    ol10)       echo "oraclelinux:10" ;;
    debian12)   echo "debian:12" ;;
    debian13)   echo "debian:13" ;;
    ubuntu2204) echo "ubuntu:22.04" ;;
    ubuntu2404) echo "ubuntu:24.04" ;;
    *) echo "" ;;
  esac
}

# Debian/Ubuntu base images ship no systemd; bake a minimal systemd layer once.
ensure_systemd_image() {
  local tag="$1" base="$2" img="guac-systemd-${tag}:local"
  case "$base" in
    oraclelinux:*) echo "$base"; return ;;
  esac
  if ! podman image exists "$img"; then
    echo ">>> building systemd base image for $tag" >&2
    podman build -q -t "$img" -f - . >&2 <<EOF
FROM ${base}
ENV container=podman DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus dbus-user-session sudo python3 iproute2 procps ca-certificates \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && find /etc/systemd/system /lib/systemd/system \
      \( -name '*.wants' -o -name '*getty*' -o -name '*udev*' \) -prune -false -o -type f -delete 2>/dev/null || true
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF
  fi
  echo "$img"
}

run_one() {
  local tag="$1" base image ctr rhel
  base="$(base_image "$tag")"
  [[ -z "$base" ]] && { echo "unknown target: $tag" >&2; exit 2; }
  ctr="guac-test-${tag}"
  image="$(ensure_systemd_image "$tag" "$base")"

  echo "=============================================================="
  echo ">>> $tag :: $base"
  echo "=============================================================="

  podman rm -f "$ctr" >/dev/null 2>&1 || true
  podman run -d --name "$ctr" --systemd=always --privileged \
    --hostname "guac-${tag}.guac.local" \
    -v "${REPO_ROOT}:/opt/guac-ansible:ro,Z" \
    "$image" /sbin/init

  for _ in $(seq 1 30); do
    state=$(podman exec "$ctr" systemctl is-system-running 2>/dev/null || true)
    [[ "$state" == "running" || "$state" == "degraded" ]] && break
    sleep 2
  done

  # Bootstrap Ansible (control tooling only — not part of the product).
  podman exec "$ctr" bash -lc '
    set -e
    if command -v dnf >/dev/null; then
      dnf -y install "oracle-epel-release-el$(rpm -E %rhel)" >/dev/null 2>&1 || \
        dnf -y install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm" >/dev/null
      dnf -y install ansible >/dev/null 2>&1 || { dnf -y install ansible-core >/dev/null; NEED_GALAXY=1; }
    else
      export DEBIAN_FRONTEND=noninteractive
      apt-get update >/dev/null
      apt-get install -y --no-install-recommends ansible >/dev/null 2>&1 || \
        { apt-get install -y --no-install-recommends ansible-core >/dev/null; NEED_GALAXY=1; }
    fi
    mkdir -p /root/guac && cp -a /opt/guac-ansible/. /root/guac/
    if [ -n "${NEED_GALAXY:-}" ]; then cd /root/guac && ansible-galaxy collection install -r requirements.yml >/dev/null; fi
  '

  echo ">>> $tag :: playbook (run 1)"
  podman exec "$ctr" bash -lc 'cd /root/guac && ansible-playbook site.yml'

  echo ">>> $tag :: idempotence (converge, then a fully clean run)"
  podman exec -e ANSIBLE_NOCOLOR=1 -e ANSIBLE_FORCE_COLOR=0 "$ctr" bash -lc '
    cd /root/guac
    for attempt in 1 2; do
      out=$(ansible-playbook site.yml 2>&1)
      echo "$out" | grep -A1 "PLAY RECAP"
      echo "$out" | grep -Eq "failed=0" || { echo "PLAYBOOK FAILED ('"$tag"')"; exit 1; }
      echo "$out" | grep -Eq "changed=0[[:space:]].*failed=0" && exit 0
    done
    echo "IDEMPOTENCE FAILED ('"$tag"')"; exit 1
  '

  echo ">>> $tag :: functional checks"
  podman exec "$ctr" bash -lc 'cd /root/guac && bash test/check.sh'

  echo ">>> $tag :: PASS"
  [[ "$KEEP" == "1" ]] || podman rm -f "$ctr" >/dev/null
}

for t in "${TAGS[@]}"; do run_one "$t"; done
echo
echo "ALL TARGETS PASSED: ${TAGS[*]}"
