# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-09-10)

**Core value:** `ansible-playbook site.yml` on a fresh RHEL 9/10 host → working Guacamole login over HTTPS reverse proxy.
**Current focus:** Phase 1 — Ansible scaffold + RHEL base

## Status

| Phase | Name | Status |
|-------|------|--------|
| 1 | Ansible scaffold + RHEL base | ◆ In progress |
| 2 | Database + guacd from source | ○ Pending |
| 3 | Guacamole web client on Tomcat | ○ Pending |
| 4 | Nginx reverse proxy + self-signed TLS | ○ Pending |
| 5 | Optional extension roles | ○ Pending |
| 6 | Two-distro Podman test harness | ○ Pending |

## Notes

- Autonomous run requested: build until Guacamole launches and `guacadmin` logs in through the
  HTTPS proxy on both Oracle Linux 9 and 10 containers. No interactive gates.
- Testing: never run Ansible on the laptop. Spawn OL9/OL10 systemd Podman containers, run the
  playbook inside (local connection), verify there. Podman host is arm64.
- Reference repo studied at scratchpad/reference (itiligent/Easy-Guacamole-Installer, Guacamole 1.6.0).
- Do not push upstream. Local git only.

---
*Last updated: 2026-09-10 after initialization*
