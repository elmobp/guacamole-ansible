# Ansible Guacamole

## What This Is

An Ansible-native reimplementation of [itiligent/Easy-Guacamole-Installer](https://github.com/itiligent/Easy-Guacamole-Installer).
It stands up an Apache Guacamole jump-host — guacamole-server (guacd) built from source, the
Guacamole web client on Tomcat, a MariaDB/MySQL JDBC auth backend (local or a separate DB
server), an Nginx TLS-1.3 reverse proxy, toggle-driven auth/console extensions, declarative
backend connections/users, CIS-aligned hardening, and BCP/DR backup/restore — entirely through
idempotent Ansible roles instead of the original numbered bash scripts. Also ships a container
image + compose stack. Platforms: RHEL/Oracle/Rocky/Alma 9-10, Debian 12-13, Ubuntu 22.04/24.04.

## Core Value

`ansible-playbook site.yml` against a fresh supported host produces a working Guacamole login
page reachable over an HTTPS reverse proxy, with `guacadmin` able to sign in — and re-running it
(including after a `guac_version` bump) is safe and idempotent.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Dynamic Ansible roles replace every shell script in the reference repo (no `.sh` install steps)
- [ ] RHEL 9 and RHEL 10 support (dnf, firewalld, SELinux, EPEL/CRB) — reference was Debian/Ubuntu only
- [ ] guacamole-server compiled from source with a role, pinned Guacamole version, FreeRDP 2/3 aware
- [ ] Guacamole web client + JDBC/MySQL auth + MariaDB schema import, all role-driven
- [ ] Nginx reverse proxy role with self-signed TLS (production will swap in Let's Encrypt)
- [ ] Optional extensions as toggle-driven roles: TOTP, DUO, LDAP, quickconnect, history-recording, branding
- [ ] All tuning exposed as `group_vars` / role defaults (ports, versions, DB creds, cert attributes, proxy DNS name)
- [ ] Idempotent: a second run makes no changes
- [ ] Molecule/CI-style verification in Podman containers (Oracle Linux 9 + 10)

### Out of Scope

- Debian / Ubuntu / Raspbian support — reference already covers it; this is the RHEL counterpart
- Live Let's Encrypt issuance in test — mimic a signed cert now; production host has real DNS + LE
- LDAP/AD end-to-end auth testing — no directory available; role installs + configures, login test is DB-only
- Enterprise tiered/cluster MySQL backend split — not needed for the jump-host use case
- Pushing anything upstream to GitHub — local repo only

## Context

- Reference repo cloned to scratchpad for study. Flow understood: system prep → MariaDB → build
  guacd from source → deploy war + jdbc + connector/j → guacamole.properties + guacd.conf →
  DB + schema → systemd enable guacd/tomcat → optional extension jars → Nginx proxy → self-signed TLS.
- Reference Guacamole version: 1.6.0. MySQL Connector/J: 9.3.0.
- Nginx proxy_pass target: `http://localhost:8080/guacamole/` with websocket upgrade headers +
  Tomcat `RemoteIpValve` for real client IPs.
- Self-signed TLS: `openssl req -x509`, nginx `listen 443 ssl` + `listen 80` → 301 redirect.
- Testing constraint: never run Ansible on the laptop. Spawn an Oracle Linux 9/10 Podman
  container (systemd-enabled), run the playbook inside it (local connection), verify there.
- Podman host is arm64 (Apple silicon); Oracle Linux images are multi-arch.
- guacd build deps on RHEL come from AppStream + CRB + EPEL; ffmpeg-free build acceptable if
  RPM Fusion unavailable (guacd still builds without libavcodec, loses some codecs).

## Constraints

- **Tech stack**: Ansible (roles + group_vars), no shell install scripts. YAML + Jinja2 templates only.
- **Platform**: RHEL 9 / RHEL 10 family. `ansible_os_family == "RedHat"`.
- **Testing**: Podman containers only, spawned by the assistant; laptop never runs Ansible directly.
- **Delivery**: local git repo at project root; never pushed upstream.
- **TLS**: self-signed / mimicked signed cert for now; Let's Encrypt path stubbed for production.
- **Completion bar**: do not stop until Guacamole launches and `guacadmin` can log in through the
  HTTPS reverse proxy in both an OL9 and an OL10 container.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Reimplement as Ansible roles, not wrap the scripts | User wants dynamic, idempotent, no shell | — Pending |
| Build guacd from source (not distro/EPEL package) | EPEL guacamole-server lags; reference builds from source; guarantees pinned version | — Pending |
| Install Tomcat from Apache binary tarball | RHEL 9/10 have no reliable tomcat package; tarball is deterministic across both | — Pending |
| Test with playbook run *inside* the target container (local connection) | Satisfies "don't run ansible on laptop"; simplest; still exercises every role | — Pending |
| Mimic signed cert via self-signed role for now | No public DNS in test; production will use Let's Encrypt role | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-09-10 after initialization*
