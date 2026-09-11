# Ansible Guacamole — cross-platform, hardened, upgrade-friendly

An Ansible-native reimplementation of
[itiligent/Easy-Guacamole-Installer](https://github.com/itiligent/Easy-Guacamole-Installer).
No numbered shell scripts — everything is an idempotent role.

## Documentation

- **[docs/INSTALL.md](docs/INSTALL.md)** — step-by-step install, assumes no Ansible knowledge
- **[docs/CONFIGURE.md](docs/CONFIGURE.md)** — every variable explained in plain English
- **[docs/SCENARIOS.md](docs/SCENARIOS.md)** — copy-paste configs (separate DB, MFA, LDAP, RDP/SSH targets, prod TLS, FIPS, ...)
- **[docs/OPERATIONS.md](docs/OPERATIONS.md)** — upgrades, backup/restore/DR runbook, hardening, containers
- **[docs/FIREWALL.md](docs/FIREWALL.md)** — every port and data flow, for firewall change requests
- **[docs/LLD-RHEL-IRAP.md](docs/LLD-RHEL-IRAP.md)** — copy-and-complete low-level design for a RHEL build, with a scoped Australian ISM control mapping
- **[docs/architecture.drawio](docs/architecture.drawio)** — data-flow architecture diagram (open in [draw.io](https://app.diagrams.net))
- **[docs/manual/](docs/manual/)** — the full operator manual, no Ansible knowledge assumed; build it to PDF with `make manual`

**Supported platforms**

| Family | Releases |
|--------|----------|
| RHEL / Oracle / Rocky / Alma | 9, 10 |
| Debian | 12, 13 |
| Ubuntu | 22.04, 24.04, 26.04 LTS |

It builds a Guacamole jump-host:

- `guacamole-server` (guacd) **compiled from source** at a pinned version
- Guacamole web client on **Apache Tomcat** (official binary tarball)
- **MariaDB** JDBC auth backend — local or a **separate/remote DB server**
- **Nginx** reverse proxy, **TLS 1.3 only**, self-signed by default (Let's Encrypt for production)
- **Single sign-on**, one primary method per host: OpenID Connect, SAML 2.0,
  X.509 client-certificate / smart card, or CAS — all toggle-driven, layered over the DB
- Every optional extension behind an independent host-var toggle:
  TOTP, Duo, LDAP/AD, Quick Connect, History Recording Storage, dark-theme branding
- **`scripts/configure.py`** — interactive Q&A that asks which auth method you want and writes the host_vars
- **One-line upgrades** — bump `guac_version`, re-run
- **BCP/DR** — `guac-backup` / `guac-restore`, scheduled, integrity-checked, optionally encrypted
- **CIS-aligned hardening** (L1/L2), optional **FIPS**
- **Container image** + compose stack

## Layout

```
site.yml                 # full build (roles run in order)
ansible.cfg
inventory/hosts.ini      # default: localhost, local connection
group_vars/all.yml       # EVERY tunable
requirements.yml         # ansible.posix, community.mysql
roles/
  common/                # repos, packages, firewall (firewalld/ufw), SELinux, guacd user, GUACAMOLE_HOME
  database/              # MariaDB (local|remote), DB/user, schema import + upgrade scripts, connector/j
  guacd/                 # build + install guacamole-server, guacd.conf, systemd unit
  guacamole_client/      # Tomcat, guacamole.war, JDBC extension, guacamole.properties, stale-artifact pruning
  nginx_proxy/           # reverse proxy, RemoteIpValve, TLS 1.3 self-signed, Let's Encrypt (opt)
  guac_extensions/       # TOTP / Duo / LDAP / OpenID / SAML / SSL-cert / CAS / quickconnect / histrec / branding — toggle-driven
  backup/                # guac-backup + guac-restore, systemd timer (BCP/DR)
  hardening/             # CIS-aligned OS + app hardening, guacd TLS, FIPS (opt-in)
container/
  Containerfile          # builds an appliance image by running the roles at build time
  docker-compose.yml     # Guacamole + MariaDB
  entrypoint.sh          # runtime process orchestration (guacd + Tomcat)
test/
  run.sh                 # 6-distro Podman matrix: build + idempotence + functional checks
  check.sh               # functional verification
  dr.sh                  # backup on host A -> restore on host B -> verify data + login
  upgrade.sh             # install old version -> bump guac_version -> verify upgrade
```

## Usage

```bash
ansible-galaxy collection install -r requirements.yml
# edit inventory + group_vars/all.yml — at minimum:
#   guac_db_password, guac_mysql_root_password, guac_proxy_site   (use a vault)
ansible-playbook -i inventory/hosts.ini site.yml
```

Browse to `https://<guac_proxy_site>/` and log in as `guacadmin` / `guacadmin` (change it immediately).

### Key variables (`group_vars/all.yml`)

| Variable | Default | Purpose |
|---|---|---|
| `guac_version` | `1.6.0` | Guacamole version. **Bump it and re-run to upgrade.** |
| `guac_tomcat_version` | `9.0.121` | Apache Tomcat tarball version |
| `guac_proxy_site` | `<fqdn>` | DNS name for the proxy + TLS cert |
| `guac_install_mariadb` | `true` | `false` → use `guac_mysql_host` (separate DB server) |
| `guac_db_bootstrap` | `true` | create DB/user + load schema; `false` if a DBA owns the DB |
| `guac_db_password` / `guac_mysql_root_password` | placeholders | **override via vault** |
| `guac_tls_mode` | `self-signed` | `self-signed` \| `letsencrypt` \| `none` (all TLS 1.3 only) |
| `guac_le_dns_name` / `guac_le_email` | empty | required for `guac_tls_mode=letsencrypt` |
| `guac_totp_enabled` … `guac_branding_enabled` | all `false` | per-extension toggles (nothing installed unless enabled) |
| `guac_guacd_tls_enabled` | `false` | wrap the internal webapp↔guacd link in TLS 1.3 |
| `guac_hardening_enabled` / `guac_hardening_level` | `true` / `l2` | CIS-aligned hardening |
| `guac_hardening_ssh_password_auth` | `true` | set `false` for key-only SSH |
| `guac_fips_enabled` | `false` | opt-in; needs a reboot, can lock you out |
| `guac_backup_enabled` | `true` | scheduled `guac-backup` timer |
| `guac_backup_gpg_passphrase` | empty | non-empty → AES-256 encrypt backup bundles |

### Extensions

Enable per host in `host_vars/<host>.yml`, e.g.:

```yaml
guac_totp_enabled: true
guac_ldap_enabled: true
guac_ldap:
  hostname: "dc1.corp.example dc2.corp.example"
  port: 636
  encryption_method: ssl
  search_bind_dn: "svc-guac@corp.example"
  search_bind_password: "{{ vault_ldap_bind_pw }}"
  config_base_dn: "dc=corp,dc=example"
  user_base_dn: "OU=Staff,DC=corp,DC=example"
  username_attribute: sAMAccountName
  user_search_filter: "(objectClass=user)"
  max_search_results: 200
```

Re-running with a toggle flipped installs (or removes) **only** that extension — no rebuild.

### Separate / remote database

```yaml
guac_install_mariadb: false
guac_mysql_host: "db01.corp.example"
guac_mysql_port: 3306
guac_mysql_admin_user: "root"          # used only to bootstrap DB/user/schema
guac_mysql_root_password: "{{ vault_remote_db_admin_pw }}"
guac_db_password: "{{ vault_guac_db_pw }}"
# or, if a DBA manages the database entirely:
guac_db_bootstrap: false
```

### Upgrades

Change one line and re-run:

```yaml
guac_version: "1.6.1"
```

`guacd` is rebuilt from the new source, the war and every extension jar are refreshed at the new
version, stale-version artifacts are removed, and JDBC `schema/upgrade/*.sql` scripts are applied
in order (tracked by `/etc/guacamole/.guac_schema_version`). Verified by `test/upgrade.sh`.

### Production TLS (Let's Encrypt)

```yaml
guac_tls_mode: letsencrypt
guac_le_dns_name: guac.example.com     # public DNS, port 80 reachable
guac_le_email: admin@example.com
```

### Backup / restore (BCP/DR)

- `guac-backup` — one restorable bundle: DB dump + `/etc/guacamole` (properties, extensions, lib,
  marker) + nginx TLS/site config; `MANIFEST` + `SHA256SUMS`; optional GPG (AES-256) encryption;
  retention pruning. Scheduled by `guac-backup.timer` (`guac_backup_schedule_oncalendar`).
- `guac-restore <bundle>` — on a host already provisioned by this playbook: stops services,
  overlays `/etc/guacamole` (old kept as `.pre-restore-<ts>`), reloads the DB, restores TLS,
  restarts, and waits for a 200 from Guacamole.
- **DR runbook:** provision host B with `ansible-playbook site.yml`, copy the latest bundle over,
  run `guac-restore`. Verified end-to-end by `test/dr.sh`.

### Hardening

`roles/hardening` applies a CIS-aligned subset on every supported OS: sysctl/kernel, module
blacklist, core-dump disable, `login.defs` ageing + `UMASK 027`, SSH drop-in (no root login,
modern KEX/ciphers/MACs, `MaxAuthTries 4`, L2 disables agent/TCP forwarding), sensitive-file
perms, cron/at allow-lists, `auditd` + baseline rules, `ctrl-alt-del` masked, Tomcat shutdown
port disabled + error-report valve, nginx `server_tokens off` + HSTS/secure headers, optional
guacd daemon TLS. **TLS 1.3 only** everywhere TLS is terminated or initiated.

This is a strong baseline, not a certified benchmark run — full CIS L2 also needs partition/mount
layout, a host IDS/AIDE, centralised logging and a scanner pass, which are environment-specific.
`guac_hardening_level: l1` relaxes the intrusive L2 controls.

**FIPS** (`guac_fips_enabled: true`): RHEL runs `fips-mode-setup --enable` (reboot required);
Ubuntu needs Ubuntu Pro (`pro enable fips-updates`); Debian has no supported FIPS module.

## Container image

```bash
podman build -t guacamole-appliance:local -f container/Containerfile .
podman-compose -f container/docker-compose.yml up -d      # or: docker compose
# http://localhost:8080/guacamole/   (guacadmin / guacadmin)
```

The image is built by running the same roles with `guac_container_build=true` (service
start/enable, firewall and SELinux management are skipped); `entrypoint.sh` runs guacd + Tomcat
and bootstraps the schema into the compose MariaDB on first start.

## Testing (Podman — never runs Ansible on your workstation)

```bash
test/run.sh                       # full matrix: ol9 ol10 debian12 debian13 ubuntu2204 ubuntu2404 ubuntu2604
test/run.sh ol9 ubuntu2404        # a subset
test/dr.sh ol9                    # backup/restore across two hosts
test/upgrade.sh ol9 1.5.5 1.6.0   # upgrade path
```

Each `run.sh` target: fresh systemd container → `site.yml` → converge to `changed=0` →
`check.sh` (four services active, login page over `:8080` and the HTTPS proxy, `guacadmin`
obtains an API token through the proxy).

## Differences from the reference

| Reference (Debian/Ubuntu, shell) | Here |
|---|---|
| `apt`, numbered `*.sh` | `dnf`/`apt`, idempotent roles, one `site.yml` |
| Debian/Ubuntu only | + RHEL/Oracle/Rocky/Alma 9–10 |
| `ufw` | `firewalld` (RHEL) / `ufw` (Debian) |
| distro `tomcat` package | Apache Tomcat binary tarball + systemd unit |
| MySQL root password prompt | MariaDB `unix_socket` root auth locally; admin creds only for remote bootstrap |
| interactive `1-setup.sh` menu | `group_vars` / `host_vars` |
| TLS 1.2+ | **TLS 1.3 only** |
| manual hardening scripts | `hardening` role (CIS-aligned) + FIPS opt-in |
| DB-only cron dump | `backup`/`restore` BCP-DR bundles |
