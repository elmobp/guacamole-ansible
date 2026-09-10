# Requirements: Ansible Guacamole Installer (RHEL edition)

**Defined:** 2026-09-10
**Core Value:** `ansible-playbook site.yml` against a fresh RHEL 9/10 host yields a working Guacamole login over HTTPS reverse proxy.

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

- [ ] **DEB-01**: `site.yml` also runs on Debian 12/13 and Ubuntu 22.04/24.04 (`ansible_os_family == "Debian"`)
- [ ] **DEB-02**: Package/repo/service logic branches by OS family (apt, ufw, no SELinux/EPEL) via role vars
- [ ] **DEB-03**: guacd build deps, Tomcat, MariaDB, Nginx all resolve on Debian family
- [ ] **DEB-04**: RHEL 9/10 continues to pass unchanged after the refactor
- [ ] **DEB-05**: `test/run.sh` matrix covers ol9, ol10, debian12, debian13, ubuntu2204, ubuntu2404

### Container Image

- [ ] **IMG-01**: `Containerfile`/`Dockerfile` builds a Guacamole image by running the roles at build time
- [ ] **IMG-02**: `docker-compose.yml` / `podman-compose` brings up Guacamole + MariaDB
- [ ] **IMG-03**: Image exposes 8080 (and 443 when proxy baked in) and starts guacd + tomcat (+ nginx)
- [ ] **IMG-04**: Compose stack reaches a working `guacadmin` login
- [ ] **IMG-05**: Image build documented in README

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
| Debian/Ubuntu/Raspbian | Reference repo already covers these; this project is the RHEL counterpart |
| Live Let's Encrypt in tests | No public DNS/inbound 80 in Podman; self-signed mimics it, production uses the LE toggle |
| LDAP/AD login testing | No directory server available; role configures but login verification is DB-only |
| Enterprise tiered MySQL cluster split | Not needed for a single jump-host |
| Windows/Linux client cert import automation | Manual step in reference; documented, not automated |
| Pushing to GitHub / upstream PR | User: local repo only |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| REPO-01..05 | Phase 1 | Pending |
| PLAT-01..05 | Phase 1 | Pending |
| DB-01..05 | Phase 2 | Pending |
| GUACD-01..04 | Phase 2 | Pending |
| CLIENT-01..05 | Phase 3 | Pending |
| PROXY-01..06 | Phase 4 | Pending |
| EXT-01..06 | Phase 5 | Pending |
| TEST-01..04 | Phase 6 | Pending |

**Coverage:**
- v1 requirements: 40 total
- Mapped to phases: 40
- Unmapped: 0 ✓

---
*Requirements defined: 2026-09-10*
*Last updated: 2026-09-10 after initial definition*
