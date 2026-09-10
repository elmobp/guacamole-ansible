---
gsd_state_version: "1.0"
status: in-progress
stopped_at: milestone-1 matrix validation (ubuntu2604 idempotence)
last_updated: "2026-09-11T06:00:00.000Z"
state_head: 1b85215
---

# Project State

## Project Reference

See: .planning/PROJECT.md · Roadmap: .planning/ROADMAP.md · Requirements: .planning/REQUIREMENTS.md

**Core value:** `ansible-playbook site.yml` on a fresh supported host → working Guacamole login
over an HTTPS TLS-1.3 reverse proxy; re-running (incl. `guac_version` bump) is idempotent.

## Active: 2026-09-11 — milestone-1 full-matrix validation (post FreeRDP-3.15 + block-notify fixes)

## Milestone 1 (Phases 1–9)

| Area | State |
|---|---|
| RHEL 9 / RHEL 10 | ✅ validated — fresh container, full `site.yml` (all 9 roles), idempotent `changed=0`, guacadmin login via HTTPS proxy |
| Debian 12 | ✅ validated — full build, idempotent `changed=0`, checks green |
| Debian 13 | ✅ validated — full build, idempotent `changed=0`, checks green; needed FreeRDP-3.15 fix `a5c006c` (`guac_server_configure_cppflags`) |
| Ubuntu 22.04 | ✅ validated — full build, idempotent `changed=0`, checks green; needed block-notify fix `1b85215` |
| Ubuntu 24.04 | ✅ validated — full build, idempotent `changed=0`, checks green (FreeRDP 3.x path) |
| Ubuntu 26.04 | ✅ validated — full build, idempotent `changed=0`, checks green; needed chrony fix `b359f52` |
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
| — FreeRDP 3.15 build fix (Debian 13 / Ubuntu 24.04+) | ✅ validated | a5c006c |
| 15 full CIS L2 coverage | ○ planned (vendor ansible-lockdown CIS + OpenSCAP gate) |
| 16 deep ISM alignment + LLD rewrite | ○ planned |
| 17 operator manual → PDF | ○ planned |
| 18/19/20 | ❌ descoped 2026-09-11 (Puppet/Nix/Chef/Terraform + AWS + Azure) | |

## Validation status (2026-09-11)

- **Full 7-distro matrix GREEN**: ol9, ol10, debian12, debian13, ubuntu2204, ubuntu2404, ubuntu2604
  — full `site.yml`, idempotent `changed=0`, `check.sh` all green.
- Session fixes: FreeRDP 3.15 build (`a5c006c`), block-notify→task-notify (`1b85215`),
  run.sh failure propagation (`ea1f39b`) + source guard (`aeafb87`), chrony/26.04 idempotence (`b359f52`).
- **`test/dr.sh ol9` PASSED** — backup host A → restore fresh host B → guacadmin login + marker
  connection intact. Needed dr.sh fix `2a1d…` (stream bundle A→B; macOS `/tmp` is a symlink).
- Still TODO: `test/upgrade.sh ol9 1.5.5 1.6.0` (running), `podman build` image smoke,
  phase-11 source-ref smoke (`-e guac_source_ref=1.6.0` on ol9).

```
cd ~/Documents/Projects/claude
test/dr.sh ol9 ; test/upgrade.sh ol9 1.5.5 1.6.0
podman build -t guacamole-appliance:local -f container/Containerfile .
```

## Resume

Say "resume". Next: close out ubuntu2604 idempotence, then dr/upgrade/image smoke,
then Phase 15 (CIS L2) / 16 (ISM+LLD) / 17 (PDF manual).

## Notes

- Never run Ansible on the laptop — Podman systemd containers only (arm64 host).
- Debian/Ubuntu apt is slow to the default CDN here; `test/run.sh` swaps to the datautama mirror
  (Debian) / ports.ubuntu.com (Ubuntu). Real deploys can set `guac_apt_mirror`.
- Reference: itiligent/Easy-Guacamole-Installer, Guacamole 1.6.0. Do not push upstream.
- Every step committed to git — closing the laptop loses only the cached container images.

---
*Last updated: 2026-09-10 (pause after phases 10–14)*

## Session

**Last session:** 2026-09-10T20:59:34.580Z
**Stopped at:** context exhaustion at 75% (2026-09-10)
**Resume file:** None
