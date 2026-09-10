# Firewall Requirements

All flows for an `ansible-guacamole` deployment. Use this to raise firewall change requests.
See `docs/architecture.drawio` for the visual.

Legend: **C** = client subnet, **G** = the Guacamole host, **DB** = separate database server
(only if `guac_install_mariadb: false`), **T** = a backend target host, **A** = the Ansible
control node, **NTP/DNS/PROXY** = your existing infrastructure services.

---

## 1. Inbound to the Guacamole host (G)

| # | Source | Dest | Port / Proto | Purpose | Condition |
|---|--------|------|--------------|---------|-----------|
| I1 | C (admin/user subnets) | G | **TCP 443 / HTTPS (TLS 1.3)** | Guacamole web UI + WebSocket tunnel | always |
| I2 | C | G | **TCP 80 / HTTP** | 301 redirect to 443 **only** | always (redirect); also ACME if `guac_tls_mode: letsencrypt` |
| I3 | A (control node / bastion) | G | **TCP 22 / SSH** | Ansible provisioning + admin | always |
| I4 | C | G | **TCP 8080 / HTTP** | direct Tomcat | **only if `guac_install_nginx: false`** (not recommended) |
| I5 | Let's Encrypt validation servers (Internet) | G | **TCP 80** | HTTP-01 ACME challenge | **only** `guac_tls_mode: letsencrypt` |
| I6 | monitoring subnet | G | TCP 443 / your agent port | health checks / metrics | optional, site-specific |

The playbook's own firewall (`firewalld` / `ufw`, `guac_manage_firewall: true`) opens **22, 80,
443** and closes **8080** when the proxy is enabled. It does **not** manage upstream/edge
firewalls — I1–I3 must still be permitted there.

## 2. Outbound from the Guacamole host (G)

### 2a. To backend targets (the reason Guacamole exists)

| # | Source | Dest | Port / Proto | Purpose | Condition |
|---|--------|------|--------------|---------|-----------|
| O1 | G | T (Windows) | **TCP 3389 / RDP** | RDP sessions | per connection using `rdp` |
| O2 | G | T (Linux/network) | **TCP 22 / SSH** | SSH sessions / SFTP | per connection using `ssh` |
| O3 | G | T | **TCP 5900–5906 / VNC** | VNC sessions | per connection using `vnc` |
| O4 | G | T | **TCP 23 / telnet** | telnet sessions | per connection using `telnet` (discouraged) |
| O5 | G | Kubernetes API | **TCP 6443 / HTTPS** | `kubernetes` protocol console | per connection using `kubernetes` |

Scope O1–O5 to the *specific* target hosts/subnets each connection needs — do **not** allow the
jump-host broad egress to the target network.

### 2b. To the database (only when `guac_install_mariadb: false`)

| # | Source | Dest | Port / Proto | Purpose | Condition |
|---|--------|------|--------------|---------|-----------|
| O6 | G | DB | **TCP 3306 / MySQL** | JDBC auth + connection/permission store | remote DB only |

If the DB is local (default) this traffic never leaves `127.0.0.1`.

### 2c. To infrastructure services

| # | Source | Dest | Port / Proto | Purpose | Condition |
|---|--------|------|--------------|---------|-----------|
| O7 | G | DNS resolvers | **UDP/TCP 53** | name resolution | always |
| O8 | G | NTP servers | **UDP 123** | time sync (critical for TLS, TOTP, auditd) | always |
| O9 | G | LDAP/AD DCs | **TCP 636 / LDAPS** (or 389 STARTTLS) | directory auth | `guac_ldap_enabled: true` |
| O10 | G | SMTP relay | **TCP 587 / 25** | alerts (if you wire up mail) | optional |
| O11 | G | Duo API (`*.duosecurity.com`) | **TCP 443** | Duo MFA | `guac_duo_enabled: true` |
| O12 | G | syslog / SIEM collector | **TCP 6514 / UDP 514** | forward `auditd` + app logs | recommended |
| O13 | G | backup target (NFS/S3/SSH) | your transfer port | ship `guac-backup` bundles off-box | recommended |

### 2d. Build / update time (can be via a proxy; can be closed between changes)

| # | Source | Dest | Port / Proto | Purpose | Condition |
|---|--------|------|--------------|---------|-----------|
| O14 | G | distro mirrors (`dnf`/`apt`) | **TCP 443 / 80** | OS packages, build deps | during `site.yml` runs |
| O15 | G | `dlcdn.apache.org`, `archive.apache.org` | **TCP 443** | guacamole-server source, war, jdbc, Tomcat | during `site.yml` runs |
| O16 | G | `repo1.maven.org` | **TCP 443** | MySQL Connector/J jar | during `site.yml` runs |
| O17 | G | EPEL / RPM Fusion mirrors | **TCP 443** | build deps (RHEL family) | RHEL, during runs |
| O18 | G | `acme-v02.api.letsencrypt.org` | **TCP 443** | certificate issuance/renewal | `guac_tls_mode: letsencrypt` |

For **air-gapped / IRAP** builds: pre-stage O14–O18 artifacts on an internal mirror and set the
`guac_apache_dl_base`, `guac_tomcat_dl_base`, `guac_mysql_connector_j_url`,
`guac_jdbc_archive_url` variables (and your `dnf`/`apt` repo config) to point at it. The only
runtime egress then required is O1–O13.

## 3. Ansible control node (A)

| # | Source | Dest | Port / Proto | Purpose |
|---|--------|------|--------------|---------|
| A1 | A | G | **TCP 22 / SSH** | run `site.yml` |
| A2 | A | Git server | TCP 443/22 | pull this repo |
| A3 | A | Galaxy / internal mirror | TCP 443 | `ansible-galaxy collection install` (once) |

## 4. Loopback-only (never leaves the host — informational)

| Flow | Port |
|------|------|
| nginx → Tomcat | 127.0.0.1:8080 |
| Tomcat → guacd | 127.0.0.1:4822 (TLS 1.3 if `guac_guacd_tls_enabled`) |
| Tomcat/guac-backup → local MariaDB | 127.0.0.1:3306 / `mysql.sock` |

## 5. Minimum production ruleset (local DB, self-signed or LE, LDAP + Duo + syslog)

```
# inbound
allow  C   -> G : tcp 443
allow  C   -> G : tcp 80            # redirect (+ ACME if LE)
allow  A   -> G : tcp 22
# outbound
allow  G   -> <RDP targets>   : tcp 3389
allow  G   -> <SSH targets>   : tcp 22
allow  G   -> <VNC targets>   : tcp 5900-5906
allow  G   -> <AD DCs>        : tcp 636
allow  G   -> api.duosecurity.com : tcp 443
allow  G   -> <DNS>           : udp/tcp 53
allow  G   -> <NTP>           : udp 123
allow  G   -> <SIEM>          : tcp 6514
allow  G   -> <backup target> : <port>
# build windows only (otherwise deny)
allow  G   -> <mirrors/Apache/Maven/ACME> : tcp 443
deny   G   -> any   (default)
deny   any -> G     (default)
```
