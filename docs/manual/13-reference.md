# 13. Reference

## 13.1 File and path map

| Path | What lives there |
|---|---|
| `/etc/guacamole/` (`guac_home`) | `GUACAMOLE_HOME` — properties file, extensions, lib, schema marker, versioned wars |
| `/etc/guacamole/guacamole.properties` | Main webapp config (templated, don't hand-edit) |
| `/etc/guacamole/guacd.conf` | guacd's own config (bind host/port, TLS) |
| `/etc/guacamole/extensions/` | Installed extension jars |
| `/etc/guacamole/lib/` | Supporting jars (MySQL Connector/J) |
| `/etc/guacamole/guacamole-<version>.war` | The version-qualified Guacamole webapp |
| `/etc/guacamole/.guac_schema_version` | Applied JDBC schema version marker |
| `/etc/guacamole/ssl/` | guacd's own TLS material (only if `guac_guacd_tls_enabled`) |
| `/etc/guacamole/ssl-auth/client-ca.pem` | X.509 client-cert issuing CA bundle (only if X.509 auth + `guac_ssl_auth_manage_nginx`) |
| `/opt/tomcat` (`guac_tomcat_home`) | Symlink to the versioned Tomcat install |
| `/opt/tomcat/webapps/guacamole.war` | Symlink into `guac_home`'s versioned war |
| `/opt/tomcat/logs/catalina.out` | Tomcat/Guacamole stdout+stderr |
| `/usr/local/src/guacamole` (`guac_build_dir`) | Source downloads / build area (guacd source, extension archives) |
| `/usr/local` (`guac_server_prefix`) | guacd's `./configure --prefix` — `sbin/guacd` lives under here |
| `/usr/local/sbin/guacd`, `guac-backup`, `guac-restore` | Installed binaries/scripts |
| `/etc/nginx/conf.d/guacamole.conf` | nginx reverse-proxy vhost(s) |
| `/etc/nginx/nginx.conf` | Main nginx config |
| `/etc/nginx/ssl/cert/`, `/etc/nginx/ssl/private/` (`guac_ssl_cert_dir`/`guac_ssl_key_dir`) | TLS certificate / key |
| `/var/log/nginx/{access,error}.log` | nginx logs |
| `/var/backups/guacamole` (default `guac_backup_dir`) | Backup bundles |
| `/var/lib/guacamole/recordings` (`guac_histrec_path`) | Session recordings, if enabled |
| `/var/lib/guacd`, `/var/guacamole` | guacd account home / shared runtime dir |
| `/etc/audit/rules.d/90-guac-hardening.rules` | Baseline auditd rules |
| `/etc/sysctl.d/90-guac-hardening.conf` | Hardening sysctl settings |
| `/etc/ssh/sshd_config.d/50-guac-hardening.conf` | SSH hardening drop-in |
| `/etc/rsyslog.d/90-guac-forward.conf` | Central log forwarding config |

## 13.2 systemd units

| Unit | Provided by | Notes |
|---|---|---|
| `guacd.service` | `roles/guacd` | `Restart=on-failure`; runs as the `guac_guacd_account` user |
| `tomcat.service` | `roles/guacamole_client` | `After=guacd.service`, `Wants=guacd.service`; `Restart=on-failure` |
| `nginx.service` | OS package (managed by `roles/nginx_proxy`) | only present when `guac_install_nginx: true` |
| `mariadb.service` | OS package (managed by `roles/database`) | only present when `guac_install_mariadb: true` |
| `guac-backup.service` / `guac-backup.timer` | `roles/backup` | timer schedule: `guac_backup_schedule_oncalendar` |
| `certbot-renew.timer` (or distro equivalent) | OS `certbot` package | only when `guac_tls_mode: letsencrypt`; not managed by this repo directly |

## 13.3 Every `group_vars/all.yml` variable

The authoritative plain-English explanation of each of these — including every optional key
inside the dictionary variables (`guac_ldap`, `guac_openid`, `guac_saml`, `guac_ssl_auth`,
`guac_cas`, `guac_duo`) — is **`docs/CONFIGURE.md`**. This table exists so every variable that
appears in `group_vars/all.yml` is accounted for somewhere in this manual, including the
internal/rarely-touched ones `docs/CONFIGURE.md` summarises rather than lists individually.
Defaults shown are the current values in `group_vars/all.yml` at the time this manual was
written (2026-09-11, `guac_version: 1.6.0`) — treat the file itself as ground truth if they ever
drift.

### Versions and download mirrors

| Variable | Default | Meaning |
|---|---|---|
| `guac_version` | `1.6.0` | Guacamole release. Bump + re-run to upgrade (Chapter 7). |
| `guac_mysql_connector_j_version` | `9.3.0` | MySQL JDBC driver version. |
| `guac_tomcat_version` | `9.0.121` | Tomcat tarball version. |
| `guac_tomcat_major` | `9` | Tomcat major line — used to build the download URL. |
| `guac_apache_dl_base` | `https://dlcdn.apache.org/guacamole/{{ guac_version }}` | Primary Guacamole download mirror. |
| `guac_apache_archive_base` | `https://archive.apache.org/dist/guacamole/{{ guac_version }}` | Fallback mirror if the primary 404s (older releases roll off dlcdn). |
| `guac_tomcat_dl_base` | dlcdn Tomcat URL | Primary Tomcat download mirror. |
| `guac_tomcat_archive_base` | archive.apache.org Tomcat URL | Fallback Tomcat mirror. |
| `guac_mysql_connector_j_url` | Maven Central URL | Where the Connector/J jar is fetched from. |

### Paths (rarely changed)

| Variable | Default | Meaning |
|---|---|---|
| `guac_home` | `/etc/guacamole` | `GUACAMOLE_HOME`. |
| `guac_extensions_dir` | `{{ guac_home }}/extensions` | Extension jars. |
| `guac_lib_dir` | `{{ guac_home }}/lib` | Supporting jars. |
| `guac_build_dir` | `/usr/local/src/guacamole` | Source/build area. |
| `guac_tomcat_home` | `/opt/tomcat` | Symlink to the installed Tomcat. |
| `guac_server_prefix` | `/usr/local` | guacd's `./configure` install prefix. |

### System identity

| Variable | Default | Meaning |
|---|---|---|
| `guac_manage_hostname` | `false` | If `true`, sets the OS hostname to `guac_fqdn` + an `/etc/hosts` entry. |
| `guac_server_name` | `{{ ansible_hostname }}` | Short host name; used in `guac_fqdn` and RDP labels. |
| `guac_local_domain` | `guac.local` | DNS suffix for `guac_fqdn`. |
| `guac_fqdn` | `{{ guac_server_name }}.{{ guac_local_domain }}` | Derived FQDN. |
| `guac_proxy_site` | `{{ guac_fqdn }}` | DNS name browsers use / the TLS cert subject. **Set this.** |

### Build / packaging behaviour

| Variable | Default | Meaning |
|---|---|---|
| `guac_container_build` | `false` | Set automatically by the container image build — skips systemd/firewall/SELinux management. Don't set by hand outside `container/Containerfile`. |
| `guac_apt_mirror` | `""` | Optional regional apt mirror (Debian/Ubuntu). |
| `guac_apt_security_mirror` | `http://security.debian.org/debian-security` | Debian security mirror. |
| `guac_enable_epel` | `true` | Enable EPEL (RHEL family). |
| `guac_enable_crb` | `true` | Enable CRB/PowerTools (RHEL family). |
| `guac_enable_rpmfusion` | `false` | Enable RPM Fusion for `ffmpeg-devel` (optional RDP codecs). |
| `guac_extra_build_packages` | `[]` | Extra OS packages to install before building. |

### Firewall / SELinux

| Variable | Default | Meaning |
|---|---|---|
| `guac_manage_firewall` | `true` | Manage `firewalld`/`ufw`. Opens 22/80/443; opens 8080 only when nginx is disabled. |
| `guac_firewall_extra_ports` | `[]` | Extra ports to open, e.g. `["3306/tcp"]`. |
| `guac_manage_selinux` | `true` | Set SELinux booleans the proxy needs (RHEL, enforcing hosts). |

### guacd service account and build flags

| Variable | Default | Meaning |
|---|---|---|
| `guac_guacd_account` | `guacd` | Service account guacd runs as. |
| `guac_guacd_bind_host` | `127.0.0.1` | Where guacd listens. |
| `guac_guacd_bind_port` | `4822` | guacd's port. |
| `guac_server_configure_extra` | `""` | Extra `./configure` flags for guacamole-server, e.g. `--enable-allow-freerdp-snapshots`. |
| `guac_server_configure_cppflags` | `-Wno-error=deprecated-declarations` | `CPPFLAGS` for `./configure` — keeps FreeRDP 3.x deprecation warnings from failing the `-Werror` build on Debian 13 / Ubuntu 24.04+ (Chapter 12.2). |

### Database

| Variable | Default | Meaning |
|---|---|---|
| `guac_install_mariadb` | `true` | Install a local MariaDB; `false` = separate/remote DB server. |
| `guac_secure_mariadb` | `true` | Apply `mysql_secure_installation`-equivalent lockdown (local only). |
| `guac_db_bootstrap` | `true` | Create the DB + user + import schema. |
| `guac_mysql_host` | `localhost` | DB server hostname/IP (remote DB). |
| `guac_mysql_port` | `3306` | DB port. |
| `guac_db_name` | `guacamole_db` | Database name. |
| `guac_db_user` | `guacamole_user` | Database user Guacamole connects as. |
| `guac_db_password` | placeholder | **Override in vault.** |
| `guac_mysql_root_password` | placeholder | Local root password, or remote admin password used once to bootstrap. **Override in vault.** |
| `guac_mysql_admin_user` | `root` | Admin account for remote-DB bootstrap. |
| `guac_db_timezone` | `UTC` | Default DB timezone; `""` skips timezone configuration (Chapter 12.5). |
| `guac_db_backup_enabled` | `true` | **Legacy/currently unused** — no task in this codebase reads it; the backup role's own toggle is `guac_backup_enabled`. Kept for naming continuity with the reference project. |
| `guac_db_backup_dir` | `/var/backups/guacamole` | Feeds `guac_backup_dir`'s default in `roles/backup` (`guac_backup_dir: "{{ guac_db_backup_dir | default(...) }}"`). |
| `guac_db_backup_retention_days` | `30` | Feeds `guac_backup_retention_days`'s default the same way. |
| `guac_db_backup_schedule` | `0 0 * * 1-5` (cron syntax) | **Legacy/currently unused** — the backup role's actual schedule is the systemd-`OnCalendar` `guac_backup_schedule_oncalendar`, below. |

### RDP display labels

| Variable | Default | Meaning |
|---|---|---|
| `guac_rdp_share_host` | `{{ guac_server_name }}` | Hostname compiled into guacd for the RDP virtual drive share. |
| `guac_rdp_share_label` | `RDP Share` | Label for the RDP virtual drive. |
| `guac_rdp_printer_label` | `RDP Printer` | Label for the RDP virtual printer. |

### Reverse proxy / TLS

| Variable | Default | Meaning |
|---|---|---|
| `guac_install_nginx` | `true` | Put Guacamole behind nginx. `false` exposes Tomcat on `:8080` directly. |
| `guac_url_redirect` | `true` | When nginx is disabled, redirect `/` → `/guacamole` on Tomcat. |
| `guac_tls_mode` | `self-signed` | `self-signed` \| `letsencrypt` \| `none`. All TLS 1.3 only (Chapter 6). |
| `guac_cert_rsa_keylength` | `3072` | Self-signed key size (ISM guidance: ≥3072). |
| `guac_cert_country` | `AU` | Self-signed cert subject field. |
| `guac_cert_state` | `Victoria` | Self-signed cert subject field. |
| `guac_cert_location` | `Melbourne` | Self-signed cert subject field. |
| `guac_cert_org` | `Itiligent` | Self-signed cert subject field. |
| `guac_cert_ou` | `I.T.` | Self-signed cert subject field. |
| `guac_cert_days` | `3650` | Self-signed cert lifetime, days. |
| `guac_ssl_cert_dir` | `/etc/nginx/ssl/cert` | Where the cert file is written. |
| `guac_ssl_key_dir` | `/etc/nginx/ssl/private` | Where the key file is written. |
| `guac_le_dns_name` | `""` | Required for `letsencrypt` — public FQDN. |
| `guac_le_email` | `""` | Required for `letsencrypt` — expiry notification address. |

### Optional extensions — MFA, LDAP, console features

| Variable | Default | Meaning |
|---|---|---|
| `guac_totp_enabled` | `false` | TOTP MFA (Chapter 5.3). |
| `guac_duo_enabled` | `false` | Duo MFA (Chapter 5.4). Fill `guac_duo`. |
| `guac_ldap_enabled` | `false` | LDAP/AD auth or group lookups (Chapter 5.2 / 3.4). Fill `guac_ldap`. |
| `guac_quickconnect_enabled` | `false` | Ad-hoc "Quick Connect" bar in the UI. |
| `guac_histrec_enabled` | `false` | History Recording Storage. |
| `guac_histrec_path` | `/var/lib/guacamole/recordings` | Where recordings are written. |
| `guac_branding_enabled` | `false` | Dark-theme branding jar. |
| `guac_ldap` | see `docs/CONFIGURE.md` | Dictionary: `hostname`, `port`, `username_attribute`, `encryption_method`, `search_bind_dn`, `search_bind_password`, `config_base_dn`, `user_base_dn`, `user_search_filter`, `max_search_results`, plus RBAC keys `group_base_dn`/`member_attribute`/`member_attribute_type`/`group_name_attribute`. |
| `guac_duo` | see `docs/CONFIGURE.md` | Dictionary: `api_hostname`, `integration_key`, `secret_key`, `application_key`. |

### Single sign-on / federated authentication

| Variable | Default | Meaning |
|---|---|---|
| `guac_openid_enabled` | `false` | OpenID Connect (Chapter 5.5a). Fill `guac_openid`. |
| `guac_saml_enabled` | `false` | SAML 2.0 (Chapter 5.5b). Fill `guac_saml`. |
| `guac_ssl_auth_enabled` | `false` | X.509 client-cert/smart-card (Chapter 5.5c). Fill `guac_ssl_auth` + `guac_ssl_auth_*`. |
| `guac_cas_enabled` | `false` | CAS (Chapter 5.5d). Fill `guac_cas`. |
| `guac_openid` | see `docs/CONFIGURE.md` | Dictionary: `authorization_endpoint`, `jwks_endpoint`, `issuer`, `client_id`, `redirect_uri`, `username_claim_type`, `groups_claim_type`, `scope`, and optional advanced keys. |
| `guac_saml` | see `docs/CONFIGURE.md` | Dictionary: `idp_metadata_url` (or `idp_url`+`entity_id`), `callback_url`, `group_attribute`, `strict`, `debug`, `compress_request`, `compress_response`, `x509_cert_path`, `private_key_path`. |
| `guac_ssl_auth` | see `docs/CONFIGURE.md` | Dictionary: `auth_uri`, `primary_uri`, `client_certificate_header`, `client_verified_header`, `subject_username_attribute`, `subject_base_dn`, `max_token_validity`, `max_domain_validity`. |
| `guac_ssl_auth_manage_nginx` | `true` | Let the nginx role add the cert-verifying vhost + header-scrubbing. |
| `guac_ssl_auth_client_ca` | `""` | PEM bundle of the client-cert issuing CA(s) (vault). |
| `guac_ssl_auth_domain` | `""` | `server_name` for the cert-verifying vhost. |
| `guac_cas` | see `docs/CONFIGURE.md` | Dictionary: `authorization_endpoint`, `redirect_uri`, `clearpass_key`. |

### Internal guacd TLS

| Variable | Default | Meaning |
|---|---|---|
| `guac_guacd_tls_enabled` | `false` | Encrypt the webapp↔guacd link with TLS 1.3. |

### Hardening

| Variable | Default | Meaning |
|---|---|---|
| `guac_hardening_enabled` | `true` | Apply the CIS-aligned hardening role (Chapter 9). |
| `guac_hardening_level` | `l2` | `l1` \| `l2`. |
| `guac_hardening_ssh_password_auth` | `true` | `false` for key-only SSH. |
| `guac_fips_enabled` | `false` | Opt-in FIPS crypto (Chapter 9.3). |
| `guac_hardening_time_sync` | `true` | Install/enable chrony. |
| `guac_hardening_ntp_servers` | `[]` | NTP servers; empty = distro pool. |
| `guac_syslog_target` | `""` | Central log collector `host:port`; empty = no forwarding (Chapter 9.4). |
| `guac_syslog_protocol` | `tcp` | `tcp` \| `udp`. |
| `guac_auto_patch` | `false` | dnf-automatic / unattended-upgrades (security updates only). |
| `guac_session_timeout_minutes` | `15` | Guacamole web session inactivity timeout; `0`/`""` = Guacamole's own default (60). |
| `guac_syslog_tls` | `false` | TLS-wrap the forwarded log stream. |
| `guac_syslog_relp` | `false` | Use RELP instead of plain `omfwd`. |
| `guac_syslog_tls_permitted_peer` | `""` | Expected collector CN/SAN. |
| `guac_syslog_tls_ca` | `""` | PEM: collector CA (vault). |
| `guac_syslog_tls_cert` | `""` | PEM: client cert — optional mutual TLS (vault). |
| `guac_syslog_tls_key` | `""` | PEM: client key (vault). |

### Backup / BCP-DR

| Variable | Default | Meaning |
|---|---|---|
| `guac_backup_enabled` | `true` | Install and schedule `guac-backup` (Chapter 8). |
| `guac_backup_gpg_passphrase` | `""` | Non-empty = AES-256 encrypt bundles. |
| `guac_backup_schedule_oncalendar` | `*-*-* 00:30:00` | systemd `OnCalendar` for `guac-backup.timer`. |

### Declarative connections / groups / users

| Variable | Default | Meaning |
|---|---|---|
| `guac_connection_groups` | `[]` | See Chapter 4. |
| `guac_connections` | `[]` | See Chapter 4. |
| `guac_users` | `[]` | See Chapter 3. |
| `guac_connections_prune` | `false` | Delete anything not declared above (Chapter 3.3). |
| `guac_user_groups` | `[]` | RBAC groups matching LDAP/SSO group names (Chapter 3.4). |

### Default admin

| Variable | Default | Meaning |
|---|---|---|
| `guac_default_admin_user` | `guacadmin` | Account the JDBC schema creates; used by the playbook itself to verify login and to authenticate connection reconciliation (Chapter 3.5). |
| `guac_default_admin_password` | `guacadmin` | **Change this in the UI right after install**, and keep this variable in sync if you change it directly rather than replacing the account (Chapter 3.5). |

### Build from source ref

| Variable | Default | Meaning |
|---|---|---|
| `guac_source_repo` | `https://github.com/apache/guacamole-server` | Repo to clone guacd from when `guac_source_ref` is set. |
| `guac_source_ref` | `""` | Branch/tag/commit to build guacd from instead of the pinned release tarball. Empty = use the release tarball. |

## 13.4 Log locations, quick reference

| Log | Location |
|---|---|
| Tomcat / Guacamole webapp | `/opt/tomcat/logs/catalina.out`, `journalctl -u tomcat` |
| guacd | `journalctl -u guacd` |
| nginx | `/var/log/nginx/access.log`, `/var/log/nginx/error.log` |
| MariaDB | `journalctl -u mariadb` |
| auditd | `/var/log/audit/audit.log` (`ausearch`/`aureport`) |
| Central collector (if forwarding configured) | your SIEM/collector |

## 13.5 Useful one-liners

```bash
# Service status at a glance
systemctl status mariadb guacd tomcat nginx --no-pager

# What Guacamole/schema version is this host on?
cat /etc/guacamole/.guac_schema_version

# What extensions are installed right now?
ls -1 /etc/guacamole/extensions/

# Direct Tomcat check (bypasses nginx)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/guacamole/

# Proxy + login check
curl -sk -d 'username=guacadmin&password=<password>' https://127.0.0.1/api/tokens

# nginx config sanity check before reload
sudo nginx -t

# On-demand backup
sudo /usr/local/sbin/guac-backup

# Re-converge without changing intent (confirms idempotence / heals drift)
ansible-playbook site.yml

# Only reconcile connections/groups/users
ansible-playbook site.yml --tags connections
```
