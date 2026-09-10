# Project State

## Project Reference

See: .planning/PROJECT.md · Roadmap: .planning/ROADMAP.md · Requirements: .planning/REQUIREMENTS.md

**Core value:** `ansible-playbook site.yml` on a fresh supported host → working Guacamole login
over an HTTPS TLS-1.3 reverse proxy; re-running (incl. `guac_version` bump) is idempotent.

## Paused: 2026-09-10 — HEAD `f980ea5` (43 commits) — working tree clean, no containers running

## Milestone 1 (Phases 1–9)

| Area | State |
|---|---|
| RHEL 9 / RHEL 10 | ✅ validated — fresh container, full `site.yml` (all 9 roles), idempotent `changed=0`, guacadmin login via HTTPS proxy |
| Debian 12 | ✅ validated through the whole build; `/etc/modprobe.d` fix committed |
| Debian 13 / Ubuntu 22.04 / 24.04 / 26.04 | ◆ code paths in place; container CI not yet run green |
| 9 roles (common, database, guacd, guacamole_client, nginx_proxy, guac_extensions, connections, backup, hardening) | ✅ implemented |
| Docs: README + INSTALL/CONFIGURE/SCENARIOS/OPERATIONS/FIREWALL/LLD-RHEL-IRAP + architecture.drawio | ✅ |
| container/ (Containerfile + compose + entrypoint) | ◆ implemented, image build not yet smoke-tested |
| `.github/workflows/ci.yml` | ✅ lint + 7-distro build matrix + per-distro image matrix + guacd cache |

## Milestone 2

| Phase | State | Commit |
|---|---|---|
| 10 CI guacd cache + per-distro images | ✅ code | d675686 |
| 11 build guacd from a git ref (`guac_source_ref`) | ✅ code | cf2f572 |
| 12 RDP session load balancing (BALANCING groups) | ✅ code | 5814ceb |
| 13 LDAP-group RBAC (`guac_user_groups` + ldap-group props) | ✅ code | 45a3953 |
| 14 external log forwarding over TLS / RELP+TLS | ✅ code | a66489d |
| 15 full CIS L2 coverage | ○ planned (vendor ansible-lockdown CIS + OpenSCAP gate) |
| 16 deep ISM alignment + LLD rewrite | ○ planned |
| 17 operator manual → PDF | ○ planned |
| 18 iac/ multi-tool (puppet/nix/chef/terraform-cdk) | ○ planned — RECOMMEND trimming to one; needs user decision |
| 19 AWS Python CDK stack | ○ blocked on user creds; must destroy after test |
| 20 Azure stack | ○ blocked on user creds; must destroy after test |

## Phases 10–14 — NOT yet run live (context ran out). Validate with:

```
cd ~/Documents/Projects/claude
test/run.sh ol9                                  # smoke the base + hardening + connections + LB
test/run.sh ol9 -k ; podman exec guac-test-ol9 ansible-playbook /root/guac/site.yml -e guac_source_ref=1.6.0   # phase 11
test/run.sh debian12 debian13 ubuntu2204 ubuntu2404 ubuntu2604   # finish milestone-1 matrix
test/dr.sh ol9 ; test/upgrade.sh ol9 1.5.5 1.6.0
podman build -t guacamole-appliance:local -f container/Containerfile .
```

## Resume

Say "resume". Next sensible work: run the validation block above and fix fallout, OR start
Phase 15/16/17, OR (with a decision) Phase 18, OR (with creds) Phase 19/20.

## Notes

- Never run Ansible on the laptop — Podman systemd containers only (arm64 host).
- Debian/Ubuntu apt is slow to the default CDN here; `test/run.sh` swaps to the datautama mirror
  (Debian) / ports.ubuntu.com (Ubuntu). Real deploys can set `guac_apt_mirror`.
- Reference: itiligent/Easy-Guacamole-Installer, Guacamole 1.6.0. Do not push upstream.
- Every step committed to git — closing the laptop loses only the cached container images.

---
*Last updated: 2026-09-10 (pause after phases 10–14)*
