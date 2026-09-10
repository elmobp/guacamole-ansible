# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-09-10)

**Core value:** `ansible-playbook site.yml` on a fresh RHEL/Debian/Ubuntu host → working Guacamole login over HTTPS TLS-1.3 reverse proxy; re-running (incl. `guac_version` bump) is idempotent.
**Current focus:** Multi-distro validation + compliance docs

## Roles (all implemented)

| Role | Purpose | Status |
|------|---------|--------|
| common | repos, packages, firewall (firewalld/ufw), SELinux, guacd user, GUACAMOLE_HOME | ✓ RHEL / ◆ Debian (CI throttled) |
| database | MariaDB local/remote, schema import + upgrade scripts, connector/j | ✓ RHEL / ✓ Debian (through schema) |
| guacd | build guacamole-server from source, guacd.conf, systemd unit, optional TLS | ✓ RHEL / ◆ Debian |
| guacamole_client | Tomcat, war, JDBC ext, guacamole.properties, stale-artifact pruning, session timeout | ✓ RHEL |
| nginx_proxy | reverse proxy, RemoteIpValve, TLS 1.3 only, HSTS/CSP headers, LE (opt) | ✓ RHEL |
| guac_extensions | TOTP/Duo/LDAP/quickconnect/histrec/branding — all toggle-driven, opt-in | ✓ RHEL |
| connections | declarative connections/groups/users via custom idempotent module | ✓ RHEL (idempotent) |
| backup | guac-backup / guac-restore, systemd timer, sha256, optional GPG (BCP/DR) | ✓ RHEL (backup+restore smoke) |
| hardening | CIS-aligned OS+app, TLS1.3, chrony, syslog fwd, auto-patch, FIPS (opt-in) | ✓ RHEL |

## Validated (fresh Podman containers)

- **RHEL 9 (Oracle Linux 9)**: full `site.yml` incl. hardening/backup/connections → idempotent `changed=0` → check.sh all green (4 services, HTTPS proxy login page, `guacadmin` token via proxy). test/run.sh PASS.
- **RHEL 10 (Oracle Linux 10)**: validated iteratively (all roles, idempotent, check.sh green).
- **Debian 12**: verified through common + database (MariaDB install, DB/user, schema import) + guacd build-deps. Full container CI blocked by test-env throughput to Debian CDN (~87 kB/s); freerdp package bug fixed (freerdp3-dev→freerdp2-dev fallback).
- Debian 13 / Ubuntu 22.04 / 24.04: OS-family code paths in place, not yet run to completion.

## Deliverables

- Docs: README, docs/{INSTALL,CONFIGURE,SCENARIOS,OPERATIONS,FIREWALL,LLD-RHEL-IRAP}.md
- docs/architecture.drawio — data-flow diagram, 9 embedded brand logos
- container/{Containerfile,docker-compose.yml,entrypoint.sh}
- test/{run.sh (6-distro matrix),check.sh,dr.sh,upgrade.sh}
- LLD includes a curated 54-control Australian ISM mapping (Implemented/Partial/Customer/Not-addressed) + out-of-scope list + POA&M seed

## Next / open

1. Finish Debian 12/13 + Ubuntu 22.04/24.04 container runs (background, throttled).
2. test/dr.sh + test/upgrade.sh full runs.
3. container/ image build + compose smoke.
4. Pretty-render check of architecture.drawio.

## Notes

- Never run Ansible on the laptop. Podman systemd containers only (arm64 host).
- Reference: itiligent/Easy-Guacamole-Installer, Guacamole 1.6.0. Do not push upstream.
- Everything committed to git after each step — safe to pause any time.

---
*Last updated: 2026-09-10*
