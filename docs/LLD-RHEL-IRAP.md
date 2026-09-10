# Low-Level Design — Apache Guacamole jump-host on RHEL (IRAP-aligned)

**Component:** privileged-access gateway (browser-based RDP/SSH/VNC broker)
**Build tool:** `ansible-guacamole` (this repository)
**Reference platform:** Red Hat Enterprise Linux 9 (also Oracle/Rocky/Alma 9-10)
**Document status:** template — complete the bracketed `[…]` fields for your environment.

> This LLD describes how a single Guacamole jump-host is built and configured. It is written to
> be copied into an organisation's design set for an IRAP assessment. Section 12 maps the design
> to a scoped set of Australian **ISM** controls. The ISM control statements quoted there are
> drawn from the dataset the design author was pointed at
> (`github.com/elmobp/ism-quiz`); **the current published ISM is authoritative** — confirm
> wording, control numbers and applicability against it and your system's classification
> ([OFFICIAL: Sensitive] / [PROTECTED] / …) before relying on this table.

---

## 1. Purpose & scope

| | |
|---|---|
| **System name** | `[SYSTEM-NAME]` |
| **Classification** | `[OFFICIAL: Sensitive \| PROTECTED]` |
| **Environment** | `[PROD \| NONPROD]` |
| **Authorising officer** | `[NAME / ROLE]` |
| **Design authority** | `[NAME / ROLE]` |
| **In scope** | The Guacamole host: OS build, guacd, Tomcat + web app, database interface, reverse proxy, TLS, hardening, logging, backup. |
| **Out of scope** | Client endpoints; target servers (RDP/SSH/VNC hosts); the surrounding network, gateways and SIEM; identity provider; physical security; personnel security. These are covered by their own design/SRMP artefacts and are called out as *customer responsibility* in §12. |

The jump-host's job: terminate an authenticated HTTPS session from an administrator's browser and
proxy it, as an RDP/SSH/VNC stream, to a target host the administrator is authorised to reach —
so that no RDP/SSH/VNC listener is ever exposed to the client network and all privileged access
is funnelled through one logged, hardened, MFA-gated choke point.

---

## 2. Architecture overview

See `docs/architecture.drawio` (data-flow diagram) and `docs/FIREWALL.md` (all flows).

```
 CLIENT ZONE            GUACAMOLE JUMP-HOST (one RHEL 9 VM)              TARGET ZONE
 ┌──────────┐  HTTPS/443 ┌─────────────────────────────────────────┐  RDP 3389 ┌────────┐
 │ Admin    │───TLS 1.3─▶│ nginx ─▶ Tomcat(war) ─▶ guacd            │──────────▶│ Windows│
 │ browser  │            │  :443     :8080         :4822            │  SSH 22   ├────────┤
 └──────────┘  HTTP/80   │  (loopback between tiers)                │──────────▶│ Linux  │
                 └─301──▶ │ MariaDB :3306 (loopback)  OR  remote DB  │  VNC 5900 ├────────┤
                         │ auditd · chrony · firewalld · SELinux    │──────────▶│ consoles│
                         └─────────────────────────────────────────┘           └────────┘
        ▲ SSH/22 (mgmt)                    ▲ dnf/Apache/Maven (build windows only)
        │                                  │
 ┌────────────┐                     ┌──────────────┐
 │ Ansible    │  site.yml           │ internal repo │  (air-gap: mirror all artefacts)
 │ control    │────────────────────▶│ mirror        │
 └────────────┘                     └──────────────┘
```

**Tiers, all on one host, all inter-tier traffic on `127.0.0.1`:**

1. **nginx** — TLS 1.3 termination, HTTP→HTTPS redirect, security headers, WebSocket upgrade,
   `RemoteIpValve` X-Forwarded-* handling.
2. **Apache Tomcat 9** + `guacamole.war` — the Guacamole web application; `GUACAMOLE_HOME=/etc/guacamole`.
3. **guacd** — the native proxy daemon, **compiled from source** at a pinned version, listens
   `127.0.0.1:4822`, speaks RDP/SSH/VNC/telnet/kubernetes to targets.
4. **MariaDB** — JDBC authentication + connection/permission store. Local by default; a separate
   DB server is a single variable change.

---

## 3. Software components

### 3.1 Guacamole server (guacd)

| Item | Value |
|---|---|
| Version | `guac_version` (default `1.6.0`) |
| Source | `dlcdn.apache.org` / `archive.apache.org` (mirror internally for air-gap) |
| Build | `./configure --prefix=/usr/local --with-systemd-dir=/etc/systemd/system` → `make` → `make install` → `ldconfig` |
| Build deps (RHEL) | `gcc gcc-c++ make autoconf automake libtool` + `cairo-devel libjpeg-turbo-devel libpng-devel libuuid-devel freerdp-devel pango-devel libssh2-devel libtelnet-devel libvncserver-devel libwebsockets-devel pulseaudio-libs-devel libvorbis-devel libwebp-devel openssl-devel` (EPEL + CRB) |
| Runs as | dedicated `guacd` system account — `nologin`, password-locked, cron-denied |
| Unit | `guacd.service`, `Type=simple`, `NoNewPrivileges=true`, `ProtectSystem=full`, `RuntimeDirectory=guacd` |
| Bind | `127.0.0.1:4822` via `/etc/guacamole/guacd.conf`; optional TLS 1.3 (`guac_guacd_tls_enabled`) |
| Build hygiene | build toolchain is **removed** from the runtime image variant; on a VM, `[decide: keep for future upgrades vs. remove and re-add per change]` |

### 3.2 Guacamole web application

| Item | Value |
|---|---|
| Container | Apache Tomcat `guac_tomcat_version` (9.0.x) from the official binary tarball, `/opt/tomcat` |
| JVM | OpenJDK 17 (`java-17-openjdk-headless`), `-Djava.awt.headless=true`, `-Xmx1024m` (tune per sizing) |
| Deploy | `guacamole.war` at `/etc/guacamole/guacamole.war`, symlinked into `webapps/`; served at `/guacamole` |
| Tomcat unit | `tomcat.service`, runs as `tomcat` (system, `nologin`); shutdown port disabled (`-1`); `ErrorReportValve showReport=false showServerInfo=false` |
| Extensions | `guacamole-auth-jdbc-mysql` (always) + optional: `totp`, `duo`, `ldap`, `quickconnect`, `history-recording-storage`, branding — one variable each |
| Config | `/etc/guacamole/guacamole.properties` (0640 root:tomcat) — DB coordinates, `guacd-*`, `api-session-timeout`, extension stanzas |
| Session timeout | `guac_session_timeout_minutes` (default 15) → `api-session-timeout` |

<a id="db"></a>
### 3.3 Database

| Item | Value |
|---|---|
| Engine | MariaDB (RHEL AppStream) — local, **or** a separate MySQL/MariaDB server (`guac_install_mariadb: false`) |
| Bind (local) | UNIX socket / `127.0.0.1` only — **no TCP listener on any routable interface** |
| Schema | `guacamole-auth-jdbc` MySQL schema; import tracked by `/etc/guacamole/.guac_schema_version` |
| Accounts | app account `guacamole_user` — `SELECT,INSERT,UPDATE,DELETE` on `guacamole_db` **only**; root via `unix_socket` (no stored password) locally; admin creds (Vault) only to bootstrap a remote DB |
| Hardening | anonymous users removed, `test` DB dropped, remote root disabled (`guac_secure_mariadb`) |
| Remote link | if remote: restrict to TCP 3306 from the jump-host IP only; enable JDBC TLS at the DBMS and set `mysql-ssl-mode`/`mysql-ssl-*` (`ism-1277`) |
| Error disclosure | Guacamole returns generic auth errors; no schema detail is exposed (`ism-1278`) |
| Logs | MariaDB general/error/slow logs → SIEM when `guac_syslog_target` set |

<a id="web"></a>
### 3.4 Web application & reverse proxy

| Item | Value |
|---|---|
| nginx | RHEL AppStream; `nginx.conf` fully templated (no `sites-enabled`), `server_tokens off` |
| Listener | `:443 ssl` (default_server) → `proxy_pass http://127.0.0.1:8080/guacamole/`; `:80` → `301 https://$host$request_uri` |
| TLS | **TLS 1.3 only** (`ssl_protocols TLSv1.3`), `ssl_session_tickets off` |
| WebSocket | `Upgrade`/`Connection` maps; `proxy_read_timeout 3600s` for long sessions |
| Client IP | Tomcat `RemoteIpValve` with `internalProxies=127.0.0.1` so real client IPs reach the app logs |
| Response headers | `Strict-Transport-Security` (2y, includeSubDomains), `X-Content-Type-Options nosniff`, `X-Frame-Options SAMEORIGIN`, `Referrer-Policy strict-origin-when-cross-origin`, `Content-Security-Policy` (`guac_proxy_csp`), `Permissions-Policy` |
| Body size | `client_max_body_size 1024m` for file transfer (tune down if not needed) |
| Access logging | nginx access + error logs; denied access, errors, requests (`ism-1536`) |

---

<a id="network"></a>
<a id="net"></a>
## 4. Network & firewall design

Full flow table: **`docs/FIREWALL.md`**. Summary:

| Direction | Flow | Port/Proto | Notes |
|---|---|---|---|
| Inbound | client → host | TCP 443 | HTTPS UI + tunnel (TLS 1.3) |
| Inbound | client → host | TCP 80 | 301 redirect only (+ ACME if Let's Encrypt) |
| Inbound | Ansible/bastion → host | TCP 22 | provisioning + admin |
| Outbound | host → targets | TCP 3389 / 22 / 5900-5906 | **scoped to specific target hosts per connection** |
| Outbound | host → DNS / NTP | 53 / 123 | infrastructure |
| Outbound | host → AD DC | TCP 636 | if LDAP enabled |
| Outbound | host → Duo API | TCP 443 | if Duo enabled |
| Outbound | host → SIEM | TCP 6514 | log forwarding |
| Outbound | host → mirrors | TCP 443/80 | **build windows only** — deny otherwise; air-gap = internal mirror |

**Host firewall:** `firewalld` (`guac_manage_firewall: true`), default-deny inbound, opens 22/80/443,
closes 8080 when the proxy is enabled. **This is host-level defence in depth — it does not replace
network/gateway segmentation**, which is a `[network design]` responsibility (`ism-1181`, `ism-1182`).

**Placement:** the host sits in a dedicated management/broker zone; the client zone reaches only
:443/:80/:22; the target zone accepts only the specific broker→target flows. `[Insert your zone
diagram / VLAN IDs / gateway rules here.]`

---

<a id="os-build"></a>
## 5. Operating system

### 5.1 Build & SOE

| Item | Value |
|---|---|
| OS | RHEL 9 (`[9.x]`), minimal / server build; `[GA \| EUS]` stream |
| Provisioning | from `[golden image / kickstart / cloud image]`; then `ansible-playbook site.yml` |
| Partitioning | `[/ , /var , /var/log , /var/log/audit , /home , /tmp , /var/tmp — with nodev,nosuid,noexec where applicable per CIS]` — **decide at OS install; not done by this playbook** |
| Support | only vendor-supported majors accepted; the playbook asserts `RedHat` family + major 9/10 (`ism-1501`) |
| Time zone | UTC (`guac_db_timezone`) |

<a id="hardening"></a>
### 5.2 OS hardening

Applied by `roles/hardening` (`guac_hardening_enabled: true`, `guac_hardening_level: l2`):

- **Kernel / sysctl** (`/etc/sysctl.d/90-guac-hardening.conf`): `rp_filter=1`, no `accept_redirects`/
  `send_redirects`/`accept_source_route`, `log_martians=1`, `tcp_syncookies=1`,
  `kernel.kptr_restrict=2`, `kernel.dmesg_restrict=1`, `kernel.yama.ptrace_scope=1`,
  `kernel.randomize_va_space=2`, `fs.suid_dumpable=0`, `fs.protected_hardlinks/symlinks=1`.
- **Kernel modules** blacklisted: `cramfs freevxfs jffs2 hfs hfsplus squashfs udf` (L1) + `usb-storage` (L2).
- **Core dumps** disabled (limits.d + systemd-coredump `Storage=none`).
- **`login.defs`**: `PASS_MAX_DAYS 365`, `PASS_MIN_DAYS 1`, `PASS_WARN_AGE 7`, `UMASK 027`.
- **SSH** drop-in `/etc/ssh/sshd_config.d/50-guac-hardening.conf`: `PermitRootLogin no`,
  `PermitEmptyPasswords no`, `MaxAuthTries 4`, `LoginGraceTime 60`, `ClientAliveInterval 300`,
  `X11Forwarding no`, curated `Ciphers`/`KexAlgorithms`/`MACs`, `Banner /etc/issue.net`; L2 also
  `AllowTcpForwarding no`, `AllowAgentForwarding no`. `guac_hardening_ssh_password_auth: false`
  for key-only.
- **File permissions**: `passwd/group 0644`, `shadow/gshadow 0000`, `sshd_config 0600`,
  `crontab 0600`; `cron.allow`/`at.allow` created (root-only scheduling).
- **`ctrl-alt-del.target`** masked.
- **SELinux**: left **enforcing**; booleans `httpd_can_network_connect`, `httpd_can_network_relay`
  set so nginx may proxy to Tomcat.
- **Default accounts**: guacd/tomcat are `nologin`, locked; `guacadmin` default password change is
  mandatory at first login (`ism-0383`).

**Assurance note:** this is a CIS-*aligned* baseline. A benchmark pass (OpenSCAP with the
`xccdf_org.ssgproject...cis` profile, or CIS-CAT) is a **separate step** and will flag
environment-specific items (mount options, AIDE, PAM `pwquality`/`faillock` thresholds, banner
text, GRUB password, etc.). `[Record scan date, tool, profile, score and POA&M here.]`

<a id="app-hardening"></a>
### 5.3 Application hardening

- Tomcat: shutdown port disabled, `ErrorReportValve` locked down, unused webapps
  (`docs/examples/host-manager/manager/ROOT`) removed, conf dir `0750 tomcat:tomcat`.
- nginx: `server_tokens off`, security headers (§3.4).
- guacd: minimal `systemd` sandboxing (`NoNewPrivileges`, `ProtectSystem=full`).
- **Application control / allow-listing** (fapolicyd / SELinux `execmod`): **not configured by
  this playbook** — implement separately if your ISM profile requires it (see §12 exclusions).

---

## 6. Identity & access

<a id="access"></a>
### 6.1 Access control & sessions

- Guacamole access is **deny-by-default**: a user sees only the connections/groups they hold a
  `READ` permission on. Managed declaratively (`guac_users`, `guac_connections`,
  `guac_connection_groups`) or in the UI.
- Web session inactivity timeout: `api-session-timeout` = `guac_session_timeout_minutes`
  (default 15) (`ism-0428`, web portion).
- OS: interactive login only for `[named sudo administrators]` over SSH; service accounts
  `nologin`. Console/screen-lock for a headless server is `[N/A / covered by the VM console
  platform]`.
- Account lifecycle (create/disable/remove on role change or departure) is an
  `[IDAM process]` responsibility; LDAP-backed auth (§6.2) inherits directory disablement
  immediately.
- Logon events (success/failure, lockout) captured by auditd (`ism-0582`).
- `[Logon banner text — insert the approved warning banner; deployed to /etc/issue and /etc/issue.net]`.

<a id="auth"></a>
### 6.2 Authentication

| Method | Mechanism | Notes |
|---|---|---|
| Primary | Guacamole JDBC (username + memorised secret) **or** LDAP/AD (`guac_ldap_enabled`) | LDAPS (636) or STARTTLS; service bind account via Vault |
| MFA | TOTP (`guac_totp_enabled`) or Duo (`guac_duo_enabled`) | applies to **all** users incl. admins (`ism-0974`, `ism-1173`, `ism-1504`, `ism-1505`) |
| Phishing-resistance | **not met by TOTP** (`ism-1682`) | for phishing-resistant MFA: Duo Verified Push, or front with a WebAuthn/FIDO2 IdP via the SSO/LDAP extension `[decision]` |
| Service accounts | `guacd`, `tomcat` — system, `nologin`, password-locked; DB/LDAP/Duo secrets supplied per deployment via **Ansible Vault** (`ism-1685`) |
| Memorised-secret policy | enforced by `[the IdP / Guacamole password policy extension / directory password policy]` — Guacamole core does not enforce complexity/length; `[state where this is enforced and the parameters]` |
| Account lockout | **not provided by Guacamole core** — add `fail2ban` against the Guacamole auth log `[planned / implemented separately]` (`ism-1403`) |

<a id="privileged"></a>
### 6.3 Privileged access

- The jump-host **is** the privileged-access control point for the target estate: administrators
  never hold direct RDP/SSH to targets; they authenticate (with MFA) to Guacamole, which brokers
  the session and records it (optionally with session recording, `guac_histrec_enabled`).
- On the host itself, privileged actions are `sudo` by named admins over hardened SSH; the guacd/
  tomcat service accounts are unprivileged and cannot log on interactively (`ism-1689`) or reach
  the internet beyond the firewall policy (`ism-1653`).
- Privileged-access events (sudo, `auid!=uid` execve, `/usr/bin/sudo` exec) are in the auditd
  ruleset (`ism-1651`); ship to the SIEM via `guac_syslog_target` for central retention.
- Just-in-time / time-bound privileged access, privileged access request workflow, and dedicated
  admin workstations (SAW/PAW) are `[IDAM / PAM platform]` responsibilities.

---

<a id="crypto"></a>
## 7. Cryptography

| Aspect | Design |
|---|---|
| Protocol | **TLS 1.3 only** at nginx (`ssl_protocols TLSv1.3`) — no TLS 1.2/1.1/1.0, no downgrade (`ism-1139`) |
| Forward secrecy | inherent to TLS 1.3 — every session (`ism-1453`) |
| Cipher suites | TLS 1.3 AEAD suites only (AES-GCM / ChaCha20-Poly1305); server does not pin order |
| Key exchange | X25519 / P-256 / P-384 (`ism-1446`; FIPS curves under FIPS mode) |
| Certificate — lab | self-signed, `guac_cert_rsa_keylength` = **3072-bit RSA** (`ism-0476`, `ism-1765`), SHA-256 (`ism-1374`), SAN = proxy FQDN + host + IP |
| Certificate — prod | **Let's Encrypt** (`guac_tls_mode: letsencrypt`) or an **internal/evaluated CA** — the self-signed mode is for lab / behind-another-terminator use only (`ism-1324`) |
| Private key protection | nginx keys `root:root 0640` in `/etc/nginx/ssl/private`; guacd keys `guacd:guacd 0640` in `/etc/guacamole/ssl` (`ism-1327`) |
| Internal guacd link | plaintext loopback by default; `guac_guacd_tls_enabled` wraps it in TLS 1.3 (self-signed internal cert) |
| SSH | curated modern KEX (`curve25519-sha256`, `dh-group16-sha512`), ciphers (`aes256-gcm`, `chacha20-poly1305`), MACs (`hmac-sha2-512/256-etm`) |
| Hashing | Guacamole stores password hashes as salted SHA-256 (upstream schema) |

<a id="fips"></a>
### 7.4 Evaluated cryptography / FIPS

`guac_fips_enabled: true` (default **false**):

- RHEL: installs `crypto-policies-scripts`, runs `fips-mode-setup --enable`. **A reboot is
  required**; re-run `site.yml` afterwards to complete verification. Confirm with
  `fips-mode-setup --check`. This selects the RHEL FIPS 140-validated modules (kernel crypto,
  OpenSSL, GnuTLS, NSS) (`ism-0467`).
- Under FIPS the self-signed RSA-3072 keys and TLS 1.3 P-256/P-384 remain compliant; verify the
  JVM uses a FIPS provider if that is in your scope `[decision: BouncyCastle FIPS / system NSS]`.
- **Do not enable FIPS on a host you cannot console into** — a failed transition can block SSH.

---

## 8. Patch & vulnerability management
<a id="patching"></a>

| Aspect | Design |
|---|---|
| OS packages | refreshed on every `site.yml` run (`dnf update_cache`; explicit upgrades are `[in/out]` of the run per change policy) |
| Automatic security updates | `guac_auto_patch: true` → `dnf-automatic` (`upgrade_type = security`, `apply_updates = yes`) + timer (`ism-1695`) |
| Guacamole / Tomcat | bump `guac_version` / `guac_tomcat_version`, re-run — guacd rebuilt, war + jars refreshed, **stale-version artefacts removed** (`ism-0304`), DB `schema/upgrade/*.sql` applied in order |
| Cadence | `[2 weeks / 48 h on known-exploited — organisational SLA]` (`ism-1696`, `ism-1751`) |
| Vulnerability scanning | **external** — `[tool, frequency, credentialed?]`; feed results into the patch cycle (`ism-1698`–`ism-1703` are the scanner's job, not this build's) |
| Test before prod | validate upgrades with `test/upgrade.sh` or a staging host before the change window |

---

<a id="logging"></a>
## 9. Logging & auditing

| Source | What | Where |
|---|---|---|
| **auditd** | identity/sudoers/time/MAC/sshd changes, `/etc/guacamole` writes, privilege escalation, module load (`roles/hardening` ruleset) | `/var/log/audit/`; central via `audisp→syslog` when `guac_syslog_target` set |
| **OS** (`ism-0582`) | logon/logoff, account lockouts, service start/stop, config changes, startups/shutdowns | journald / rsyslog |
| **nginx** | access + error (denied access, errors, requests) — real client IP via `RemoteIpValve` | `/var/log/nginx/` |
| **Tomcat / Guacamole** | app events, auth success/failure, admin actions | `/opt/tomcat/logs/` |
| **guacd** | connection open/close, protocol errors | journald |
| **MariaDB** | error / (optional) general / slow | `/var/log/mariadb/` |

- **Record contents** (`ism-0585`): auditd records date/time, subject, object/filename, event
  description and host by default.
- **Time source** (`ism-0988`): `chrony` installed + enabled (`guac_hardening_time_sync`),
  `guac_hardening_ntp_servers` or distro pool; consistent UTC timestamps across sources.
- **Central storage** (`ism-1747`, `ism-1714`, `ism-1651`, `ism-1757`, `ism-1758`): set
  `guac_syslog_target` (e.g. `collector.corp:6514`, TCP) — `rsyslog` forwards everything and
  `audisp` forwards auditd. **Until set, logs are local only.**
- **Retention**: local rotation via logrotate defaults; authoritative retention is the SIEM's
  (`[X months/years per policy]`).
- **Log integrity** (`ism-0585` family): local logs are root-owned; forward off-host promptly so
  a host compromise cannot erase the authoritative copy.

<a id="monitoring"></a>
### 9.3 Monitoring & response

The build **produces** the telemetry. Timely analysis, alerting, correlation and incident
response (`ism-0109`, `ism-1228`) are **SOC/SIEM functions** — `[name the SOC, the SIEM, the
alert use-cases fed from this host: failed admin logons, auditd privilege events, nginx 4xx/5xx
spikes, guacd connection anomalies]`. A NIDS/NIPS at the gateway is a `[network]` responsibility.

---

<a id="backup"></a>
## 10. Backup & recovery (BCP/DR)

| Aspect | Design |
|---|---|
| Tool | `guac-backup` (installed on the host) + `guac-backup.timer` (`guac_backup_schedule_oncalendar`, default 00:30 daily) |
| Bundle contents | DB logical dump + `/etc/guacamole` (properties, extensions, lib, schema marker) + nginx TLS/site config; `MANIFEST` + `SHA256SUMS` (`ism-1511`) |
| Integrity | per-file SHA-256 in the bundle + a `.sha256` sidecar for the bundle |
| Encryption | `guac_backup_gpg_passphrase` → AES-256 (`gpg -c`); store the passphrase separately and durably |
| Storage & access | `/var/backups/guacamole` `0700 root:root` — unprivileged accounts cannot read backups (`ism-1812`, `ism-1705`) |
| Immutability | **partial** — `guac-backup` only prunes by retention; for `ism-1707`/`ism-1708` ship bundles to **write-once / object-lock / offline** storage `[name the target and its retention lock]` |
| Off-host copy | `[rsync/scp/S3 job — name it; a backup on the same disk is not a backup]` |
| Restore | `guac-restore <bundle>` on a freshly-provisioned host — stops services, overlays config, reloads DB, restores TLS, restarts, waits for HTTP 200 |
| DR test | `test/dr.sh` performs build-A → backup → restore-B → verify login + data; run it `[quarterly]` as part of DR exercises (`ism-1515`) |
| RPO / RTO | `[RPO = 24 h (daily) or lower with a tighter timer; RTO = time to provision a host + restore ≈ 20–40 min]` |
| DR / BCP plan | this build is the **enactment mechanism**; the plan document itself is an organisational artefact (`ism-0734`, `ism-principle-r3`) |

---

## 11. Deployment & change management

| Aspect | Design |
|---|---|
| Tool | Ansible (`ansible-core` ≥ 2.14), roles only, no shell install scripts |
| Invocation | `ansible-playbook -i inventory/hosts.ini site.yml` from `[the control node]` |
| Idempotence | a second run reports `changed=0`; verified in CI across the supported OS matrix (`test/run.sh`) |
| Secrets | Ansible Vault (`group_vars/vault.yml`); `[KMS/HSM integration if applicable]` |
| Air-gap | mirror `dnf`, `dlcdn.apache.org`, `archive.apache.org`, `repo1.maven.org`, EPEL/CRB internally; set `guac_apache_dl_base`, `guac_tomcat_dl_base`, `guac_mysql_connector_j_url`, `guac_jdbc_archive_url` and repo config accordingly |
| Container option | `container/Containerfile` + compose — same roles at build time (`guac_container_build=true`) |
| Change control | all changes are code in version control; peer-reviewed; applied via the pipeline; `[CAB reference]` |
| Configuration baseline | `group_vars/all.yml` + `host_vars/[SYSTEM-NAME].yml` are the authoritative config record |

---

## 12. ISM control mapping

**Scope of this table:** the controls that this *component build* materially implements, partly
implements, or directly supports. It is **not** a full ISM SSP — personnel, physical, gateway,
email, data-transfer, media, and application-development control families are addressed by other
artefacts. Status legend:

- ✅ **Implemented** — the build configures this by default (or via a documented default-on toggle).
- 🟡 **Partial / conditional** — implemented in part, or requires a variable to be set, or the
  build provides the capability but full compliance needs an operational step.
- 📋 **Customer responsibility** — the design supports/enables the control; an organisational
  process or another system must operate it.
- ❌ **Not addressed** — called out honestly so it lands in the POA&M.

> Control statements below are abridged from the referenced dataset. **Verify against the current
> ISM** for authoritative text, control numbers, and applicability to `[classification]`.

<!-- BEGIN ISM TABLE -->
| ISM control | Status | Design section | Coverage in this build |
|---|---|---|---|
| `ism-0109` | 📋 Customer responsibility | [§9.3 Monitoring & response](#monitoring) | The build produces the telemetry (auditd, nginx, Tomcat, guacd); timely analysis is a SOC/SIEM function. |
| `ism-0304` | ✅ Implemented | [§8 Patch management](#patching) | Superseded artifacts are removed on upgrade: old war, exploded webapp, Tomcat work cache and stale-version extension jars. |
| `ism-0383` | 🟡 Partial / conditional | [§5.2 OS hardening](#hardening) | guacd/tomcat service accounts have no interactive login; the default guacadmin password must be changed at first login (documented). Broader default-account review follows CIS guidance. |
| `ism-0428` | 🟡 Partial / conditional | [§6.1 Access control & sessions](#access) | guac_session_timeout_minutes sets the Guacamole web session inactivity timeout (default 15); OS console lock is out of scope for a headless server. |
| `ism-0467` | 🟡 Partial / conditional | [§7.4 Evaluated cryptography / FIPS](#fips) | guac_fips_enabled activates the platform FIPS 140 validated module (RHEL fips-mode-setup; Ubuntu Pro FIPS). Off by default; needs a reboot. |
| `ism-0476` | ✅ Implemented | [§7 Cryptography & TLS 1.3](#crypto) | guac_cert_rsa_keylength default 3072 (>= 2048, 3072 preferred). |
| `ism-0580` | 🟡 Partial / conditional | [§9 Logging & auditing](#logging) | An event-logging configuration (auditd rules + optional forwarding) is deployed; the governing policy is an org artefact. |
| `ism-0582` | ✅ Implemented | [§6.1 Access control & sessions](#access) | auditd baseline rules log logon/logoff, account changes, config changes, service and privilege events. |
| `ism-0734` | 📋 Customer responsibility | [§10 Backup & recovery](#backup) | The build supplies the backup/restore capability; the BCP/DR plan itself is an organisational document. |
| `ism-0974` | 🟡 Partial / conditional | [§6.2 Authentication](#auth) | guac_totp_enabled adds TOTP MFA for all users; enable per deployment. |
| `ism-0988` | ✅ Implemented | [§9 Logging & auditing](#logging) | chrony is installed and enabled (guac_hardening_time_sync) so timestamps are consistent across systems. |
| `ism-1139` | ✅ Implemented | [§7 Cryptography & TLS 1.3](#crypto) | nginx ssl_protocols TLSv1.3 only — the latest TLS version, no downgrade. |
| `ism-1173` | 🟡 Partial / conditional | [§6.2 Authentication](#auth) | The same TOTP/Duo MFA covers privileged (admin) Guacamole users. |
| `ism-1181` | 📋 Customer responsibility | [§4 Network & firewall](#net) | The jump-host is designed to sit in its own zone between client and target networks; zone creation is a network-design activity. |
| `ism-1182` | 🟡 Partial / conditional | [§4 Network & firewall](#net) | Host firewall limits ingress/egress to required flows; inter-segment enforcement is the surrounding network's responsibility (see FIREWALL.md). |
| `ism-1228` | 📋 Customer responsibility | [§9.3 Monitoring & response](#monitoring) | Forward logs (guac_syslog_target) to your SIEM; incident identification is an operational process. |
| `ism-1269` | 🟡 Partial / conditional | [§3.3 Database](#db) | guac_install_mariadb=false places the DB on a separate server; single-host default co-locates them. |
| `ism-1270` | 📋 Customer responsibility | [§3.3 Database](#db) | Place the DB server on a server segment, not a user segment, when using a remote DB. |
| `ism-1271` | 🟡 Partial / conditional | [§3.3 Database](#db) | Remote DB reachable only on 3306 from the jump-host; restrict with network ACLs to that single source. |
| `ism-1272` | ✅ Implemented | [§3.3 Database](#db) | Local MariaDB binds the UNIX socket / localhost only; JDBC traffic never leaves 127.0.0.1. |
| `ism-1273` | 📋 Customer responsibility | [§3.3 Database](#db) | Use separate DB instances for non-production; the playbook does not enforce environment separation. |
| `ism-1277` | 🟡 Partial / conditional | [§3.3 Database](#db) | Local DB link is loopback-only; for a remote DB enable JDBC TLS at the DBMS and set mysql-ssl-* in guacamole.properties. |
| `ism-1278` | ✅ Implemented | [§3.4 Web application & reverse proxy](#web) | Tomcat ErrorReportValve (showReport=false, showServerInfo=false) and nginx server_tokens off suppress version/structure disclosure. |
| `ism-1324` | 🟡 Partial / conditional | [§7 Cryptography & TLS 1.3](#crypto) | Production uses Let's Encrypt or an internal CA; the built-in self-signed mode is for lab/behind-LB use only. |
| `ism-1327` | ✅ Implemented | [§7 Cryptography & TLS 1.3](#crypto) | Private keys are root:root 0640 under /etc/nginx/ssl/private; guacd keys owned by the guacd account 0640. |
| `ism-1374` | ✅ Implemented | [§7 Cryptography & TLS 1.3](#crypto) | Certificates are generated with SHA-256 (openssl default); Let's Encrypt issues SHA-256. |
| `ism-1416` | ✅ Implemented | [§4 Network & firewall](#net) | firewalld (RHEL) / ufw (Debian) restrict inbound to 22/80/443 and close 8080 behind the proxy; default-deny. |
| `ism-1424` | ✅ Implemented | [§3.4 Web application & reverse proxy](#web) | nginx adds HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy and a Content-Security-Policy on every response. |
| `ism-1446` | 🟡 Partial / conditional | [§7 Cryptography & TLS 1.3](#crypto) | TLS 1.3 negotiates X25519 / P-256 / P-384; under FIPS mode the FIPS 186 curves are used. |
| `ism-1453` | ✅ Implemented | [§7 Cryptography & TLS 1.3](#crypto) | TLS 1.3 provides Perfect Forward Secrecy for every session by design. |
| `ism-1501` | ✅ Implemented | [§5.1 Build & SOE](#os-build) | Only vendor-supported majors are permitted (RHEL/Oracle/Rocky/Alma 9-10, Debian 12-13, Ubuntu 22.04/24.04); the playbook asserts the platform. |
| `ism-1504` | 🟡 Partial / conditional | [§6.2 Authentication](#auth) | For an internet-facing deployment, enable guac_totp_enabled or guac_duo_enabled so users MFA to the service. |
| `ism-1505` | 🟡 Partial / conditional | [§6.2 Authentication](#auth) | MFA (TOTP/Duo) gates access to Guacamole, which brokers access to target data repositories. |
| `ism-1511` | ✅ Implemented | [§10 Backup & recovery](#backup) | guac-backup bundles DB + /etc/guacamole + TLS to a single point-in-time archive; test/dr.sh restores it onto a fresh host and verifies login + data. |
| `ism-1515` | ✅ Implemented | [§10 Backup & recovery](#backup) | Restoration to a common point in time is scripted (guac-restore) and exercised by test/dr.sh. |
| `ism-1536` | 🟡 Partial / conditional | [§3.4 Web application & reverse proxy](#web) | nginx access/error logs capture denied access, errors and requests; forward centrally via guac_syslog_target. |
| `ism-1552` | ✅ Implemented | [§3.4 Web application & reverse proxy](#web) | Port 80 returns only a 301 to HTTPS; all Guacamole content is served over TLS. |
| `ism-1651` | 🟡 Partial / conditional | [§6.3 Privileged access](#privileged) | Privileged-access events (sudo, auid!=uid execve) are in the auditd ruleset; central storage requires guac_syslog_target. |
| `ism-1653` | 🟡 Partial / conditional | [§6.3 Privileged access](#privileged) | guacd/tomcat run as unprivileged nologin service accounts with no shell or outbound need; host egress is firewall-restricted. |
| `ism-1682` | ❌ Not addressed | [§6.2 Authentication](#auth) | TOTP is not phishing-resistant; use Duo with Verified Push, or front Guacamole with a WebAuthn-capable IdP (LDAP/SSO extension). |
| `ism-1685` | ✅ Implemented | [§6.2 Authentication](#auth) | Service accounts (guacd, tomcat) are system accounts, nologin, password-locked; DB creds are deployment-supplied via Vault. |
| `ism-1689` | 🟡 Partial / conditional | [§6.3 Privileged access](#privileged) | Service accounts cannot log on interactively (nologin); admin logon is via SSH to a sudo user, hardened by the SSH drop-in. |
| `ism-1695` | 🟡 Partial / conditional | [§8 Patch management](#patching) | Each site.yml run refreshes OS packages; guac_auto_patch enables dnf-automatic/unattended-upgrades for a 2-week-or-better cadence. |
| `ism-1696` | 📋 Customer responsibility | [§8 Patch management](#patching) | 48-hour patching when an exploit exists is an operational SLA; re-run site.yml or rely on guac_auto_patch + monitoring. |
| `ism-1705` | 🟡 Partial / conditional | [§10 Backup & recovery](#backup) | Backups are stored 0700 root:root; move bundles to write-once/off-host storage for full immutability. |
| `ism-1707` | 🟡 Partial / conditional | [§10 Backup & recovery](#backup) | guac-backup prunes only by retention; use immutable object storage or an appliance to prevent modification/deletion within the retention window. |
| `ism-1714` | 🟡 Partial / conditional | [§9 Logging & auditing](#logging) | Unprivileged-access events are logged by auditd; forward centrally with guac_syslog_target. |
| `ism-1747` | 🟡 Partial / conditional | [§9 Logging & auditing](#logging) | OS/auditd logs forward to a central collector when guac_syslog_target is set (rsyslog + audisp). |
| `ism-1751` | 📋 Customer responsibility | [§8 Patch management](#patching) | Patch cadence for the OS is owned by operations; the playbook makes re-patching a single idempotent run. |
| `ism-1757` | 🟡 Partial / conditional | [§3.4 Web application & reverse proxy](#web) | Web (nginx + Tomcat) logs forward to the SIEM when guac_syslog_target is set. |
| `ism-1758` | 🟡 Partial / conditional | [§3.3 Database](#db) | MariaDB logs forward to the SIEM when guac_syslog_target is set. |
| `ism-1765` | ✅ Implemented | [§7 Cryptography & TLS 1.3](#crypto) | Self-signed key length defaults to 3072-bit RSA. |
| `ism-1812` | ✅ Implemented | [§10 Backup & recovery](#backup) | The backup directory is not readable by unprivileged accounts (0700 root). |
| `ism-principle-r3` | 📋 Customer responsibility | [§10 Backup & recovery](#backup) | guac-restore + the DR runbook (OPERATIONS.md) are the enactment mechanism for the DR plan. |
<!-- END ISM TABLE -->

### 12.1 Explicitly out of scope for this build (for the POA&M / other artefacts)

| Area | ISM family (indicative) | Why / where it lives |
|---|---|---|
| Application control / execution allow-listing | ism-0843, ism-0955, ism-1490, ism-1656–1658, ism-1582 | Not configured (no fapolicyd/AppLocker policy). Implement separately if required by your profile. |
| Vulnerability scanning cadence | ism-1698–1703, ism-1752 | External scanner + process. |
| Central log **analysis** & incident response | ism-0109, ism-1228, ism-principle-d1/d2 | SOC / SIEM. |
| Evaluated firewalls / gateways / NIDS-NIPS | ism-0639, ism-1030, ism-1528 | Network / gateway design. |
| Web-application development (OWASP ASVS/Top 10) | ism-0971, ism-1239–1241, ism-1849, ism-1850 | Guacamole is upstream software, not developed here. |
| Break-glass account process | ism-1611–1615, ism-1685, ism-1795 | IDAM / PAM process. |
| Just-in-time administration, PAW/SAW | ism-1649, privileged-workstation controls | PAM platform. |
| Personnel security, overseas travel, physical | ism-1554–1556, physical family | HR / security governance. |
| Data classification & marking | ism-0393 and marking family | Information-management process. |
| Account lifecycle (joiners/movers/leavers) | ism-0430, ism-1590, ism-1591 | IDAM process (LDAP integration makes disablement immediate). |
| Backup immutability within retention | ism-1707, ism-1708 | Needs object-lock / offline storage target. |

### 12.2 Residual actions (POA&M seed)

| # | Action | Owner | Target |
|---|---|---|---|
| 1 | Run OpenSCAP/CIS-CAT against the built host; remediate/accept findings | `[SysAdmin]` | `[date]` |
| 2 | Set `guac_syslog_target` and confirm events arrive in `[SIEM]` | `[SecOps]` | `[date]` |
| 3 | Enable MFA (`guac_totp_enabled`/`guac_duo_enabled`); decide phishing-resistant path | `[IDAM]` | `[date]` |
| 4 | Configure off-host + immutable backup storage | `[BackupAdmin]` | `[date]` |
| 5 | Decide application-control approach (fapolicyd) or formally accept the risk | `[ITSA]` | `[date]` |
| 6 | Add `fail2ban` for Guacamole auth lockout | `[SysAdmin]` | `[date]` |
| 7 | Confirm partition/mount-option layout at OS build meets CIS | `[Build team]` | `[date]` |
| 8 | If FIPS in scope: enable, reboot, verify JVM provider | `[SysAdmin]` | `[date]` |

---

## 13. Appendix — key configuration values

| Variable | This build | Set for `[SYSTEM-NAME]` |
|---|---|---|
| `guac_version` | 1.6.0 | `[…]` |
| `guac_proxy_site` | `<fqdn>` | `[…]` |
| `guac_tls_mode` | self-signed | `[letsencrypt / none]` |
| `guac_install_mariadb` | true | `[…]` |
| `guac_hardening_level` | l2 | `[…]` |
| `guac_fips_enabled` | false | `[…]` |
| `guac_totp_enabled` / `guac_duo_enabled` | false | `[…]` |
| `guac_syslog_target` | (unset) | `[collector:6514]` |
| `guac_auto_patch` | false | `[…]` |
| `guac_session_timeout_minutes` | 15 | `[…]` |
| `guac_backup_gpg_passphrase` | (unset) | `[vault ref]` |

*Generated against `ansible-guacamole` @ `[commit]`. Review at each ISM release and each system change.*
