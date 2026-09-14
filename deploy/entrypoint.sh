#!/usr/bin/env bash
# Runs inside the control container (deploy/Containerfile.control). Builds an
# SSH inventory from environment variables (populated by --env-file .env in
# scripts/deploy-rhel-vm.sh) and runs the real playbook against the real host.
# No install logic here — orchestration only.
set -euo pipefail

: "${server_name:?server_name not set (check .env)}"
: "${server_ip:?server_ip not set (check .env)}"
: "${ssh_username:?ssh_username not set (check .env)}"
: "${ssh_password:?ssh_password not set (check .env)}"

INV="$(mktemp)"
trap 'rm -f "$INV"' EXIT

cat > "$INV" <<EOF
[guacamole]
${server_name} ansible_host=${server_ip} ansible_user=${ssh_username} ansible_password=${ssh_password} ansible_become_password=${ssh_password}

[guacamole:vars]
ansible_connection=ssh
ansible_become=true
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_common_args=-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
EOF

if [[ "${1:-}" == "--adhoc" ]]; then
  shift
  exec ansible -i "$INV" guacamole -m ansible.builtin.shell -a "$*" --become
fi

exec ansible-playbook -i "$INV" site.yml -e @deploy/rhel-vm-vars.yml "$@"
