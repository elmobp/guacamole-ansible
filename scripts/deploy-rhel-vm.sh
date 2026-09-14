#!/usr/bin/env bash
# Deploys the full appliance onto a real, external host over SSH — as opposed
# to test/run.sh, which provisions throwaway local containers. No install
# logic lives here; it only builds an ansible control-node image and points
# it at the target via .env (never read by anything other than podman/ansible
# themselves — see deploy/entrypoint.sh).
#
# Requires a .env file in the repo root (gitignored) defining:
#   server_hostname=  server_ip=  ssh_username=  ssh_password=
#
# Usage: scripts/deploy-rhel-vm.sh [extra ansible-playbook args]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

[[ -f .env ]] || { echo "error: .env not found in $REPO_ROOT" >&2; exit 1; }

IMG="guac-deploy-control:local"
podman build -q -t "$IMG" -f deploy/Containerfile.control . >/dev/null

exec podman run --rm -it \
  --env-file .env \
  -v "$REPO_ROOT:/workspace:Z" \
  -w /workspace \
  "$IMG" "$@"
