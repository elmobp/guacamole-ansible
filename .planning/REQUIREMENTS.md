# Requirements: Ansible Guacamole

**Defined:** 2026-09-10 · **Updated:** 2026-09-10 (multi-distro, hardening, BCP/DR, connections, CI)
**Core Value:** `ansible-playbook site.yml` against a fresh supported host yields a working Guacamole login over an HTTPS TLS-1.3 reverse proxy; re-running (incl. `guac_version` bump) is idempotent.
**Supported platforms:** RHEL/Oracle/Rocky/Alma 9-10 · Debian 12-13 · Ubuntu 22.04/24.04/26.04

## v1 Requirements

### Repo & Structure

- [ ] **REPO-01**: Repo root holds an Ansible project: `site.yml`, `ansible.cfg`, `inventory/`, `group_vars/`, `roles/`
- [ ] **REPO-02**: No shell script performs install logic; only Ansible tasks/templates/handlers
- [ ] **REPO-03**: Every reference-script setting is a documented variable in `group_vars/all.yml` or a role's `defaults/main.yml`
- [ ] **REPO-04**: `README.md` explains usage, variables, and the Podman test workflow
- [ ] **REPO-05**: Running `site.yml` a second time reports zero changed tasks (idempotent)

### Platform (RHEL 9/10)

- [ ] **PLAT-01**: Playbook asserts `ansible_os_family == "RedHat"` and supports major versions 9 and 10
- [ ] **PLAT-02**: Package installs use `dnf`; EPEL and CRB/PowerTools repos enabled by a role
- [ ] **PLAT-03**: Firewall managed via `firewalld` (ports 22, 80, 443; 8080 only when proxy disabled)
- [ ] **PLAT-04**: SELinux handled — booleans set for Nginx→Tomcat proxying, or documented context fixes
- [ ] **PLAT-05**: Services managed via `systemd` (guacd, tomcat, nginx, mariadb enabled + started)

### Database

- [ ] **DB-01**: Role installs MariaDB server (local) or configures a remote host via variables
- [ ] **DB-02**: Guacamole database + user created idempotently with a grant scoped to that DB
- [ ] **DB-03**: JDBC schema imported once from the downloaded `guacamole-auth-jdbc` archive
- [ ] **DB-04**: MySQL Connector/J jar placed in `/etc/guacamole/lib/`
- [ ] **DB-05**: Optional daily `mysqldump` backup job installed as a cron/systemd-timer via variable toggle
- [ ] **DB-06**: Remote/separate DB server supported — `guac_install_mariadb: false` + `guac_mysql_host` + root creds; role creates DB/user and imports schema over TCP
- [ ] **DB-07**: `guac_db_bootstrap` toggle to skip DB/user/schema creation entirely (DBA-managed database)

### Guacamole Server (guacd)

- [ ] **GUACD-01**: Role downloads and compiles `guacamole-server` at a pinned version from source
- [ ] **GUACD-02**: Build deps resolved for RHEL 9 and 10; FreeRDP 2.x and 3.x both accommodated
- [ ] **GUACD-03**: `guacd` runs under a locked-down service account and binds `127.0.0.1:4822` via `guacd.conf`
- [ ] **GUACD-04**: `guacd.service` installed and enabled; rebuild is skipped when the target version is already installed

### Guacamole Client & Auth

- [ ] **CLIENT-01**: Tomcat installed (Apache binary tarball) and `guacamole.war` deployed to it
- [ ] **CLIENT-02**: `guacamole-auth-jdbc-mysql` extension jar installed to `/etc/guacamole/extensions/`
- [ ] **CLIENT-03**: `guacamole.properties` templated with mysql-* connection settings
- [ ] **CLIENT-04**: `GUACAMOLE_HOME` (`/etc/guacamole`) wired to Tomcat; web app reachable on `:8080/guacamole`
- [ ] **CLIENT-05**: Default `guacadmin/guacadmin` login works after first boot (DB auth)

### Reverse Proxy & TLS

- [ ] **PROXY-01**: Nginx role proxies `/` to the Guacamole context with websocket upgrade headers
- [ ] **PROXY-02**: Tomcat `RemoteIpValve` configured so client IPs pass through
- [ ] **PROXY-03**: Self-signed TLS role generates cert/key for the proxy DNS name (mimics a signed cert)
- [ ] **PROXY-04**: Port 80 redirects (301) to 443; TLS 1.2+ only
- [ ] **PROXY-05**: Let's Encrypt role present but disabled by default (production toggle, `certbot --nginx`)
- [ ] **PROXY-06**: `guacadmin` can log in through `https://<proxy_site>/` end to end

### Optional Extensions (toggle-driven roles)

- [ ] **EXT-01**: `guac_totp_enabled` installs the TOTP extension jar
- [ ] **EXT-02**: `guac_duo_enabled` installs the DUO extension jar + property stubs
- [ ] **EXT-03**: `guac_ldap_enabled` installs the LDAP extension jar + templated `ldap-*` properties (not login-tested)
- [ ] **EXT-04**: `guac_quickconnect_enabled` installs the quickconnect extension jar
- [ ] **EXT-05**: `guac_histrec_enabled` installs history-recording-storage jar + creates the recording path
- [ ] **EXT-06**: `guac_branding_enabled` deploys the dark-theme `branding.jar`
- [ ] **EXT-07**: Every extension is independently true/false in host_vars; nothing installed unless explicitly enabled (branding included — default off)
- [ ] **EXT-08**: Enabling an extension later and re-running installs just it; disabling + re-running removes just it (no full rebuild)
- [ ] **EXT-09**: All per-extension settings (LDAP dirs, DUO keys, TOTP issuer, histrec path) are host_vars-driven and templated into `guacamole.properties`

### Verification

- [ ] **TEST-01**: A documented flow spawns an Oracle Linux 9 systemd Podman container and runs `site.yml` in it
- [ ] **TEST-02**: Same flow for Oracle Linux 10
- [ ] **TEST-03**: Automated post-checks: guacd/tomcat/nginx/mariadb active; `https://host/` returns the login page; token API auth succeeds for `guacadmin`
- [ ] **TEST-04**: Second `site.yml` run in each container is green (idempotence proof)

### Upgrades

- [ ] **UPG-01**: Bumping `guac_version` and re-running `site.yml` performs a full upgrade with no other edits
- [ ] **UPG-02**: guacd is rebuilt from the new source only when the running version differs
- [ ] **UPG-03**: Stale versioned artifacts (old war, old extension jars) are removed on upgrade
- [ ] **UPG-04**: JDBC schema `upgrade/*.sql` scripts applied idempotently on version bump
- [ ] **UPG-05**: Enabled extension jars re-fetched at the new version; `guacamole.properties` unchanged

### Debian / Ubuntu family

- [ ] **DEB-01**: `site.yml` also runs on Debian 12/13 and Ubuntu 22.04/24.04/26.04 (`ansible_os_family == "Debian"`)
- [ ] **DEB-02**: Package/repo/service logic branches by OS family (apt, ufw, no SELinux/EPEL) via role vars
- [ ] **DEB-03**: guacd build deps, Tomcat, MariaDB, Nginx all resolve on Debian family
- [ ] **DEB-04**: RHEL 9/10 continues to pass unchanged after the refactor
- [ ] **DEB-05**: `test/run.sh` matrix covers ol9, ol10, debian12, debian13, ubuntu2204, ubuntu2404, ubuntu2604
- [ ] **DEB-06**: Ubuntu 26.04 (LTS) supported — FreeRDP dev pkg resolved at runtime (freerdp3-dev → freerdp2-dev), codename-driven apt sources, `default-jre-headless`
- [ ] **DEB-07**: Optional `guac_apt_mirror` / `guac_apt_security_mirror` to point apt at a faster regional mirror

### Continuous Integration

- [ ] **CI-01**: `.github/workflows/ci.yml` runs on push/PR: lint + syntax + a build matrix
- [ ] **CI-02**: `lint` job — `yamllint`, `ansible-playbook --syntax-check`, `ansible-lint`, `shellcheck` on `test/*.sh`
- [ ] **CI-03**: `build` job — matrix over all 7 platform tags, each running `test/run.sh <tag>` (full `site.yml` → idempotence → `check.sh`) in a systemd Podman container on the GitHub runner
- [ ] **CI-04**: CI uses the default distro mirrors (GitHub runners are well-connected); the regional-mirror override is test-env only
- [ ] **CI-05**: A `ci-ok` gate job fails the workflow if any matrix leg fails

### Container Image

- [ ] **IMG-01**: `Containerfile`/`Dockerfile` builds a Guacamole image by running the roles at build time
- [ ] **IMG-02**: `docker-compose.yml` / `podman-compose` brings up Guacamole + MariaDB
- [ ] **IMG-03**: Image exposes 8080 (and 443 when proxy baked in) and starts guacd + tomcat (+ nginx)
- [ ] **IMG-04**: Compose stack reaches a working `guacadmin` login
- [ ] **IMG-05**: Image build documented in README

### Backup / Restore (BCP/DR)

- [ ] **BDR-01**: `backup` role produces a restorable bundle: DB dump + `/etc/guacamole` (properties, extensions, lib, certs) + guacd.conf
- [ ] **BDR-02**: `restore` script rebuilds a working Guacamole on a fresh host from a bundle (documented runbook)
- [ ] **BDR-03**: Backups timestamped, retained per `guac_db_backup_retention_days`, integrity-checked (sha256), optionally encrypted
- [ ] **BDR-04**: Restore verified end-to-end in the test harness (backup on host A, restore on host B, guacadmin logs in)
- [ ] **BDR-05**: Scheduled backups via cron/timer; manual `guac-backup` / `guac-restore` CLI wrappers

### Hardening

- [ ] **HRD-01**: `hardening` role, toggle `guac_hardening_enabled`, level `guac_hardening_level: l1|l2`, applied on all supported OS
- [ ] **HRD-02**: CIS-aligned controls: sysctl/kernel, SSH, auth/pam, mount options, service minimisation, auditd, firewall default-deny
- [ ] **HRD-03**: App-layer hardening: nginx (no tokens, HSTS, secure headers), Tomcat (shutdown port, no manager, error pages), guacd daemon TLS
- [ ] **HRD-04**: TLS 1.3 **only**, everywhere TLS is terminated or initiated (nginx, guacd TLS, LDAP where used)
- [ ] **HRD-05**: FIPS mode enabled where the platform supports it (`guac_fips_enabled`); documented limits (Ubuntu Pro, RHEL fips-mode-setup)
- [ ] **HRD-06**: Hardening is idempotent and does not break the guacadmin login path; documented residual CIS gaps

### Declarative connections & users

- [ ] **CONN-01**: `guac_connections` list in host_vars declares backend target servers (RDP/VNC/SSH/telnet/kubernetes) with all parameters
- [ ] **CONN-02**: `guac_connection_groups` list declares (nested) organisational groups
- [ ] **CONN-03**: `guac_users` list declares Guacamole users, passwords, group membership, permissions
- [ ] **CONN-04**: A `connections` role reconciles these into Guacamole idempotently (create/update; optional prune of unmanaged)
- [ ] **CONN-05**: Works whether auth is DB-only or LDAP (DB connections still apply)

### Documentation (non-coder friendly)

- [ ] **DOC-01**: `docs/INSTALL.md` — install Ansible + get the repo + run, per OS, zero codebase knowledge assumed
- [ ] **DOC-02**: `docs/CONFIGURE.md` — every single variable explained in plain English, grouped, with defaults
- [ ] **DOC-03**: `docs/SCENARIOS.md` — copy-paste host_vars for common setups (separate DB, TOTP, LDAP, RDP targets, prod LE, FIPS)
- [ ] **DOC-04**: `docs/OPERATIONS.md` — upgrades, backup/restore/DR runbook, hardening notes, container
- [ ] **DOC-05**: README links to all of the above; `group_vars/all.yml.example` is a fully-commented template

## v2 Requirements

### Hardening & Ops

- **OPS-01**: fail2ban role for Guacamole brute-force protection
- **OPS-02**: guacd daemon-side TLS wrapper (`add-tls-guac-daemon` equivalent)
- **OPS-03**: SMTP relay role for backup/alert email
- **OPS-04**: Upgrade role (in-place Guacamole version bump)
- **OPS-05**: Molecule scenarios wired into a real CI runner

## Out of Scope

| Feature | Reason |
|---------|--------|
| Raspbian / non-LTS Ubuntu / other distros | Not in the supported matrix |
| Live Let's Encrypt in tests | No public DNS/inbound 80 in Podman; self-signed mimics it, production uses the LE toggle |
| LDAP/AD login testing | No directory server available; role configures but login verification is DB-only |
| Enterprise tiered MySQL cluster split | Not needed for a single jump-host |
| Windows/Linux client cert import automation | Manual step in reference; documented, not automated |
| Application-control / execution allow-listing (fapolicyd) | Out of hardening scope; documented in the LLD as a POA&M item |
| Central log **analysis** / SIEM correlation | Build emits telemetry + optional forwarding; analysis is a SOC function |

## Status (2026-09-10)

| Group | State |
|---|---|
| REPO / PLAT / DB / GUACD / CLIENT / PROXY / EXT / TEST-01..04 | ✅ validated on RHEL 9 + 10 (fresh container, idempotent, guacadmin login via proxy) |
| UPG-01..05 (upgrades) | ◆ implemented; `test/upgrade.sh` written, full run pending |
| DEB-01..07 (Debian/Ubuntu incl. 26.04) | ◆ implemented; Debian 12 validated through full build; 13 / Ubuntu 22.04/24.04/26.04 CI pending |
| IMG-01..05 (container) | ◆ implemented; image build smoke test pending |
| BDR-01..05 (backup/restore) | ◆ implemented; backup+restore smoke OK on RHEL; `test/dr.sh` A→B pending |
| HRD-01..06 + chrony/syslog/auto-patch | ✅ implemented + idempotent on RHEL; TLS 1.3 only enforced |
| CONN-01..05 (declarative connections) | ✅ implemented + idempotent on RHEL |
| DOC-01..05 + FIREWALL + LLD-RHEL-IRAP + architecture.drawio | ✅ written |
| CI-01..05 (GitHub Actions) | ✅ `.github/workflows/ci.yml` added — runs on first push to GitHub |

*Note:* DOC-05's "fully-commented template" is satisfied by `group_vars/all.yml` itself (every
key carries an inline comment); no separate `.example` file.

---
*Requirements defined: 2026-09-10*
*Last updated: 2026-09-10 — cross-platform + hardening + BCP/DR + connections + CI*
