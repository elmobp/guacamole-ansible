# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-09-10)

**Core value:** `ansible-playbook site.yml` on a fresh RHEL/Debian/Ubuntu host → working Guacamole login over HTTPS reverse proxy.
**Current focus:** Multi-distro + hardening + BCP/DR + container — validation pass

## Status

| Phase | Name | Status |
|-------|------|--------|
| 1 | Ansible scaffold + RHEL base | ✓ |
| 2 | Database + guacd from source | ✓ |
| 3 | Guacamole web client on Tomcat | ✓ |
| 4 | Nginx reverse proxy + self-signed TLS | ✓ |
| 5 | Optional extension roles | ✓ |
| 6 | Two-distro Podman test harness | ✓ (RHEL 9 + 10 fresh: build + idempotent + login) |
| 7 | One-line upgrades | ◆ implemented (schema marker, stale-jar prune, guacd rebuild); test/upgrade.sh pending run |
| 8 | Container image + compose | ◆ implemented; build not yet run |
| 9 | Debian / Ubuntu family | ◆ implemented (OS-family vars); fresh-container tests pending |
| — | Backup/restore (BCP/DR) | ◆ implemented (backup role, guac-backup/restore, timer); dr.sh pending run |
| — | Hardening (CIS-aligned, TLS1.3, FIPS opt-in) | ◆ implemented; iterating on OL10 |

## Validated

- RHEL 9 (Oracle Linux 9) and RHEL 10 (Oracle Linux 10): fresh container, full `site.yml`,
  idempotent re-run (`changed=0`), `test/check.sh` green — before the multi-distro refactor.
- Post-refactor OL10: converging; hardening/backup bugs being ironed out iteratively.

## Next

1. Green OL10 with hardening+backup, then fresh OL9.
2. Fresh Debian 12 / 13, Ubuntu 22.04 / 24.04 via `test/run.sh`.
3. `test/dr.sh`, `test/upgrade.sh`, container build + compose.
4. Final full `test/run.sh` (6 distros) + doc pass.

## Notes

- Never run Ansible on the laptop. Podman systemd containers only (arm64 host).
- Reference: itiligent/Easy-Guacamole-Installer, Guacamole 1.6.0.
- Do not push upstream. Local git only.

---
*Last updated: 2026-09-10*
