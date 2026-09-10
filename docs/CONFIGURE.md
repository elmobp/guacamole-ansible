# Configuration Reference

Every setting, in plain English. Set these in **`group_vars/all.yml`** (applies to all hosts)
or **`host_vars/<hostname>.yml`** (applies to one host). Secrets belong in an Ansible Vault
file. You never need to touch anything under `roles/`.

Legend: **bold** = you will likely want to set this.

---

## Versions

| Variable | Default | Meaning |
|---|---|---|
| **`guac_version`** | `1.6.0` | Which Guacamole release to install. **Change this and re-run to upgrade** (see OPERATIONS.md). |
| `guac_tomcat_version` | `9.0.121` | Apache Tomcat version (downloaded from apache.org). Tomcat 9.x is recommended. |
| `guac_mysql_connector_j_version` | `9.3.0` | MySQL JDBC driver version. |

## Where things live (rarely changed)

| Variable | Default | Meaning |
|---|---|---|
| `guac_home` | `/etc/guacamole` | `GUACAMOLE_HOME` — config, extensions, lib. |
| `guac_tomcat_home` | `/opt/tomcat` | Symlink to the installed Tomcat. |
| `guac_build_dir` | `/usr/local/src/guacamole` | Where sources are downloaded/compiled. |
| `guac_server_prefix` | `/usr/local` | Install prefix for the compiled `guacd`. |

## Identity / DNS

| Variable | Default | Meaning |
|---|---|---|
| **`guac_proxy_site`** | `<hostname>.guac.local` | The DNS name users type in their browser, and the name on the TLS certificate. **Set this.** |
| `guac_server_name` | the host's short name | Used for `guac_fqdn` and RDP labels. |
| `guac_local_domain` | `guac.local` | DNS suffix used to build `guac_fqdn`. |
| `guac_manage_hostname` | `false` | If `true`, Ansible sets the OS hostname to `guac_fqdn` and adds an `/etc/hosts` entry. |

## Database

| Variable | Default | Meaning |
|---|---|---|
| **`guac_install_mariadb`** | `true` | `true` = install MariaDB on this host. `false` = use a **separate database server** (fill in `guac_mysql_host` etc). |
| **`guac_db_password`** | placeholder | Password for the Guacamole database user. **Change it (use Vault).** |
| **`guac_mysql_root_password`** | placeholder | Local MariaDB `root` password *or*, for a remote DB, the admin password used once to create the database/user/schema. **Change it.** |
| `guac_mysql_admin_user` | `root` | Admin account name used to bootstrap a **remote** database. |
| `guac_db_bootstrap` | `true` | Create the database, user and load the schema. Set `false` if your DBA has already done this. |
| `guac_mysql_host` | `localhost` | Hostname/IP of the database server (set this when `guac_install_mariadb: false`). |
| `guac_mysql_port` | `3306` | Database port. |
| `guac_db_name` | `guacamole_db` | Database name. |
| `guac_db_user` | `guacamole_user` | Database user Guacamole connects as. |
| `guac_secure_mariadb` | `true` | Apply `mysql_secure_installation`-equivalent lockdown (local DB only). |
| `guac_db_timezone` | `UTC` | Default DB timezone. Set `""` to skip timezone configuration. |

## Reverse proxy & TLS

| Variable | Default | Meaning |
|---|---|---|
| `guac_install_nginx` | `true` | Put Guacamole behind an Nginx reverse proxy. `false` = expose Tomcat directly on port 8080. |
| **`guac_tls_mode`** | `self-signed` | `self-signed` (lab / behind another LB), `letsencrypt` (public, real cert), or `none` (plain HTTP proxy). **All modes are TLS 1.3 only.** |
| `guac_le_dns_name` | `""` | **Required for `letsencrypt`** — the public FQDN (must resolve, port 80 reachable). |
| `guac_le_email` | `""` | **Required for `letsencrypt`** — where Let's Encrypt sends expiry warnings. |
| `guac_url_redirect` | `true` | When Nginx is disabled, redirect `/` to `/guacamole` on Tomcat. |
| `guac_cert_*` | Itiligent / AU / ... | Subject fields for the self-signed certificate (`country`, `state`, `location`, `org`, `ou`). |
| `guac_cert_days` | `3650` | Self-signed certificate lifetime in days. |
| `guac_cert_rsa_keylength` | `2048` | Self-signed key size. |

## Extensions — MFA, LDAP, console features

Each is **off by default**. Nothing is installed unless you set its toggle to `true`.

| Variable | Default | Meaning |
|---|---|---|
| `guac_totp_enabled` | `false` | Time-based one-time-password MFA (Google Authenticator etc). |
| `guac_duo_enabled` | `false` | Duo Security MFA. Fill in `guac_duo` (below). |
| `guac_ldap_enabled` | `false` | LDAP / Active Directory authentication. Fill in `guac_ldap` (below). |
| `guac_quickconnect_enabled` | `false` | "Quick Connect" ad-hoc connection bar in the UI. |
| `guac_histrec_enabled` | `false` | History Recording Storage (session recordings browsable in the UI). |
| `guac_histrec_path` | `/var/lib/guacamole/recordings` | Where recordings are written. |
| `guac_branding_enabled` | `false` | Install the dark-theme branding jar. |

`guac_ldap` (a dictionary — set the keys you need):

| Key | Meaning |
|---|---|
| `hostname` | Space-separated DC hostnames. |
| `port` | `389` (plain / STARTTLS) or `636` (LDAPS). |
| `encryption_method` | `none`, `starttls`, or `ssl`. |
| `search_bind_dn` / `search_bind_password` | Service account used to search the directory. |
| `config_base_dn` | Base DN for Guacamole config objects. |
| `user_base_dn` | Where user accounts live. |
| `username_attribute` | `sAMAccountName` (AD) or `uid` (OpenLDAP). |
| `user_search_filter` | LDAP filter selecting login-eligible users. |
| `max_search_results` | Cap on directory results (default 200). |

`guac_duo` (a dictionary): `api_hostname`, `integration_key`, `secret_key`, `application_key`
— from your Duo Admin Panel.

## Backend servers, groups and users (declarative)

Define the machines your users will connect *to*. Managed by the `connections` role; safe to
re-run. See **SCENARIOS.md** for full copy-paste examples.

`guac_connection_groups` — list of `{ name, parent, type }`:

| Key | Meaning |
|---|---|
| `name` | Group name shown in the UI. |
| `parent` | Parent group name, or `ROOT` for top level. |
| `type` | `ORGANIZATIONAL` (a folder) or `BALANCING` (a load-balanced pool). |

`guac_connections` — list of `{ name, parent, protocol, parameters, attributes }`:

| Key | Meaning |
|---|---|
| `name` | Connection name in the UI. |
| `parent` | Group name it lives in, or `ROOT`. |
| `protocol` | `rdp`, `vnc`, `ssh`, `telnet`, or `kubernetes`. |
| `parameters` | Protocol settings — e.g. `hostname`, `port`, `username`, `password`, `domain`, `security`, `ignore-cert`, `enable-drive`, ... (any Guacamole connection parameter). |
| `attributes` | Optional limits — `max-connections`, `max-connections-per-user`, `weight`, `failover-only`. |

`guac_users` — list of `{ username, password, attributes, system_permissions, connections, groups }`:

| Key | Meaning |
|---|---|
| `username` / `password` | The Guacamole login (password used on create; add `update_password: true` to force a reset). |
| `attributes` | e.g. `{ "guac-full-name": "Alice Smith", "guac-email-address": "alice@..." }`. |
| `system_permissions` | e.g. `[CREATE_CONNECTION, CREATE_USER, ADMINISTER]`. |
| `connections` | Connection names this user gets `READ` (i.e. use) permission on. |
| `groups` | Group names this user gets `READ` permission on. |

| Variable | Default | Meaning |
|---|---|---|
| `guac_connections_prune` | `false` | If `true`, connections/users **not** listed above are **deleted**. Leave `false` unless this playbook is the sole source of truth. |

## Internal guacd TLS

| Variable | Default | Meaning |
|---|---|---|
| `guac_guacd_tls_enabled` | `false` | Encrypt the internal link between the web app and `guacd` with TLS 1.3. Useful when they may run on different hosts. |
| `guac_guacd_bind_host` / `guac_guacd_bind_port` | `127.0.0.1` / `4822` | Where `guacd` listens. |

## Hardening

| Variable | Default | Meaning |
|---|---|---|
| `guac_hardening_enabled` | `true` | Apply the CIS-aligned OS + app hardening role. |
| `guac_hardening_level` | `l2` | `l1` (baseline) or `l2` (adds intrusive controls: disables SSH agent/TCP forwarding, blacklists `usb-storage`, ...). |
| `guac_hardening_ssh_password_auth` | `true` | Set `false` on hosts where you log in with SSH keys only (recommended). |
| `guac_hardening_ssh_permit_root` | `no` | `PermitRootLogin` value. |
| `guac_hardening_install_auditd` | `true` | Install and enable `auditd` with a baseline ruleset. |
| `guac_fips_enabled` | `false` | Turn on FIPS crypto. **Opt-in** — needs a reboot; on RHEL runs `fips-mode-setup --enable`; on Ubuntu needs Ubuntu Pro; Debian unsupported. Can lock you out if the platform isn't prepared. |

## Backup / BCP-DR

| Variable | Default | Meaning |
|---|---|---|
| `guac_backup_enabled` | `true` | Install and schedule the `guac-backup` job. |
| `guac_backup_dir` | `/var/backups/guacamole` | Where bundles are stored. |
| `guac_backup_retention_days` | `30` | Delete bundles older than this. |
| `guac_backup_schedule_oncalendar` | `*-*-* 00:30:00` | systemd `OnCalendar` expression for the backup timer. |
| `guac_backup_gpg_passphrase` | `""` | If set, bundles are AES-256 encrypted with this passphrase (**store it safely — you cannot restore without it**). |
| `guac_backup_include_tls` | `true` | Include `/etc/nginx/ssl` + the proxy site config in the bundle. |

## OS plumbing (usually leave as-is)

| Variable | Default | Meaning |
|---|---|---|
| `guac_manage_firewall` | `true` | Manage `firewalld` (RHEL) / `ufw` (Debian). Opens 22/80/443; opens 8080 only when the proxy is disabled. |
| `guac_firewall_extra_ports` | `[]` | Extra ports to open, e.g. `["3306/tcp"]`. |
| `guac_manage_selinux` | `true` | Set the SELinux booleans the proxy needs (RHEL, enforcing hosts). |
| `guac_enable_epel` / `guac_enable_crb` | `true` | Enable EPEL / CodeReady-Builder repos (RHEL) for build dependencies. |
| `guac_enable_rpmfusion` | `false` | Enable RPM Fusion (RHEL) to get `ffmpeg-devel` for extra codecs. |
| `guac_server_configure_extra` | `""` | Extra flags for `guacamole-server`'s `./configure` (e.g. `--enable-allow-freerdp-snapshots`). |
| `guac_rdp_share_label` / `guac_rdp_printer_label` / `guac_rdp_share_host` | RDP Share / RDP Printer / hostname | Labels compiled into `guacd` for the RDP virtual drive and printer. |
| `guac_container_build` | `false` | Internal — set automatically during container image builds; do not set by hand. |

## Default admin (verification only)

| Variable | Default | Meaning |
|---|---|---|
| `guac_default_admin_user` / `guac_default_admin_password` | `guacadmin` / `guacadmin` | The account the JDBC schema creates. The playbook uses it only to verify login works. **Change this password in the UI right after install.** |
