# Low-Level Design — Apache Guacamole jump-host on RHEL (IRAP-aligned)

**Component:** privileged-access gateway (browser-based RDP/SSH/VNC broker)
**Build tool:** `ansible-guacamole` (this repository)
**Reference platform:** Red Hat Enterprise Linux 9 (also Oracle/Rocky/Alma 9-10)
**Document status:** template — complete the bracketed `[…]` fields for your environment.

> This LLD describes how a single Guacamole jump-host is built and configured. It is written to
> be copied into an organisation's design set for an IRAP assessment. Section 12 maps the design
> to **165 Australian ISM controls**, control by control, with an honest status for each.
>
> The control statements quoted in §12 come from the dataset at
> `github.com/elmobp/ism-quiz` (`controls.json`, retrieved **2026-09-11**, 871 published ids /
> 907 after normalisation), stored verbatim in `docs/data/ism-controls.json` with provenance in
> `docs/data/ism-controls.meta.json`. **The currently published ISM at cyber.gov.au is
> authoritative** — control numbers, wording and applicability drift between quarterly releases.
> Confirm every row against the current ISM and against your system's classification
> ([OFFICIAL: Sensitive] / [PROTECTED] / …) before relying on it. The methodology, and how to
> refresh the mapping against a newer ISM, are described in `docs/ISM.md`.

---

<a id="scope"></a>
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

<a id="arch"></a>
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

<a id="guacd"></a>
### 3.1 Guacamole server (guacd)

| Item | Value |
|---|---|
| Version | `guac_version` (default `1.6.0`) |
| Source | `dlcdn.apache.org` / `archive.apache.org` (mirror internally for air-gap) |
| Build | `./configure --prefix=/usr/local --with-systemd-dir=/etc/systemd/system` → `make` → `make install` → `ldconfig` |
| Build deps (RHEL) | `gcc gcc-c++ make autoconf automake libtool` + `cairo-devel libjpeg-turbo-devel libpng-devel libuuid-devel freerdp-devel pango-devel libssh2-devel libtelnet-devel libvncserver-devel libwebsockets-devel pulseaudio-libs-devel libvorbis-devel libwebp-devel openssl-devel` (EPEL + CRB) |
| Runs as | dedicated `guacd` system account — `nologin`, password-locked, cron-denied |
| Unit | `guacd.service`, `Type=simple`, `NoNewPrivileges=true`, `ProtectSystem=full`, `RuntimeDirectory=guacd` (`ism-1250`) |
| Bind | `127.0.0.1:4822` via `/etc/guacamole/guacd.conf`; optional TLS 1.3 (`guac_guacd_tls_enabled`) |
| Build hygiene | the source tree and toolchain remain under `/usr/local/src/guacamole` on a VM build (`ism-1245`) — the container variant drops them; `[decide: keep for future upgrades vs. remove and re-add per change]` |
| Build identity | `/usr/local/.guacd_build_id` records `release:<ver>` or `src:<repo>@<ref>`; a mismatch triggers a rebuild, a match skips it (`ism-1493`) |

<a id="webapp"></a>
### 3.2 Guacamole web application

| Item | Value |
|---|---|
| Container | Apache Tomcat `guac_tomcat_version` (9.0.x) from the official binary tarball, `/opt/tomcat` |
| JVM | OpenJDK 17 (`java-17-openjdk-headless`), `-Djava.awt.headless=true`, `-Xmx1024m` (tune per sizing) |
| Deploy | `guacamole.war` at `/etc/guacamole/guacamole.war`, symlinked into `webapps/`; served at `/guacamole` |
| Tomcat unit | `tomcat.service`, runs as `tomcat` (system, `nologin`); shutdown port disabled (`-1`); `ErrorReportValve showReport=false showServerInfo=false` |
| Extensions | `guacamole-auth-jdbc-mysql` (always) + optional: `totp`, `duo`, `ldap`, `quickconnect`, `history-recording-storage`, branding — one variable each |
| SSO extensions | `guacamole-auth-sso-{openid,saml,ssl,cas}` — OpenID Connect, SAML 2.0, X.509 client certificate / smart card, CAS. Each is an **identity layer over** the JDBC store: the IdP proves who you are, the database still holds connections and permissions (`ism-1682`, `ism-1504`) |
| Extension hygiene | jars for disabled features and stale versions are pruned from `extensions/` on every run (`ism-1247`) |
| Config | `/etc/guacamole/guacamole.properties` (0640 root:tomcat) — DB coordinates, `guacd-*`, `api-session-timeout`, extension stanzas |
| Session timeout | `guac_session_timeout_minutes` (default 15) → `api-session-timeout` |
| REST API | every call carries an auth token from `/api/tokens`; reads are permission-filtered and writes require the matching system/object permission (`ism-1817`, `ism-1818`) |

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

**Assurance note:** `roles/hardening` is a CIS-*aligned* baseline, not a certified CIS L2 pass.
Full CIS L2 coverage plus an OpenSCAP gate is delivered by **`roles/cis`** — see that role for
the benchmark profile, the accepted-deviation list and the score target. The ISM has no direct
CIS mapping, but the CIS Benchmarks satisfy much of what `ism-1409` ("ACSC and vendor hardening
guidance for operating systems is implemented") asks for; the control statements in §12 are
anchored to what `roles/hardening` verifiably does **today**, so that table does not depend on
`roles/cis` landing.

Known items `roles/hardening` does **not** do (all covered by `roles/cis`, and each has a §12
row or a §12.2 action): partition and mount options, AIDE file-integrity monitoring, PAM
`pwquality`/`faillock` thresholds (`ism-1403`), approved banner text in `/etc/issue.net`
(`ism-0408`), GRUB password, auditd immutable mode.
`[Record scan date, tool, profile, score and accepted deviations here.]`

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
| Primary — database | Guacamole JDBC (username + memorised secret), salted SHA-256 hashes in `guacamole_user` | default; hashes are salted but **not stretched** (`ism-1402`) |
| Primary — directory | LDAP/AD (`guac_ldap_enabled`) | LDAPS (636) or STARTTLS; service bind account via Vault; group RBAC via `guac_user_groups` |
| Primary — SSO | **OpenID Connect** (`guac_openid_enabled`), **SAML 2.0** (`guac_saml_enabled`), **CAS** (`guac_cas_enabled`) | identity layer over the JDBC store; `saml-strict: true` enforces signature/cert validation; OIDC validates issuer, JWKS, nonce and token validity (`ism-1603`) |
| Primary — certificate | **X.509 client certificate / smart card** (`guac_ssl_auth_enabled`) | nginx verifies the client cert against `guac_ssl_auth_client_ca` and forwards the result; the primary vhost **scrubs** the `X-Client-*` headers so a browser cannot forge an identity |
| MFA | TOTP (`guac_totp_enabled`) or Duo (`guac_duo_enabled`) | applies to **all** users incl. admins — Guacamole cannot exempt an account from a loaded MFA extension (`ism-0974`, `ism-1173`, `ism-1504`, `ism-1505`) |
| Phishing-resistance | achievable (`ism-1682`) | **TOTP is not phishing-resistant.** Use X.509 client-certificate auth (smart card), or OIDC/SAML to an IdP enforcing WebAuthn/FIDO2. `[state the chosen path]` |
| Service accounts | `guacd`, `tomcat` — system, `nologin`, password-locked, cron-denied; DB/LDAP/Duo/SSO secrets supplied per deployment via **Ansible Vault** (`ism-1685`) | the `ChangeMe_*` defaults in `group_vars/all.yml` **must** be overridden |
| Target credentials | stored in `guacamole_connection_parameter` on the broker, recoverable by design (`ism-0418`) | mitigated by loopback-only DB, `0640` properties and encrypted backups; avoid with RDP/SSH credential pass-through or per-user prompting `[decision]` |
| Memorised-secret policy | enforced by `[the IdP / directory password policy]` — Guacamole core enforces no length or complexity (`ism-0421`); `[state where this is enforced and the parameters]` |
| Account lockout | **not implemented** (`ism-1403`) — Guacamole core has none and `pam_faillock` is not configured by `roles/hardening`; add `fail2ban` against the Guacamole auth log and see `roles/cis` for PAM `faillock` `[planned / implemented separately]` |

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
| Forward secrecy | inherent to TLS 1.3: ephemeral-only key establishment, `ssl_session_tickets off` (`ism-1448`, `ism-1453`) |
| Cipher suites | TLS 1.3 AEAD suites only (AES-GCM / ChaCha20-Poly1305); server does not pin order (`ism-1369`). Note TLS_AES_128_GCM_SHA256 remains negotiable — constrain the crypto policy if AES-192+ is mandated |
| No renegotiation / no compression | both removed by the TLS 1.3 protocol itself (`ism-1370`, `ism-1553`) |
| Key exchange | OpenSSL default group order leads with **X25519**, then P-256 / P-384. X25519 is *not* a FIPS 186 curve (`ism-1446`, `ism-1761`) — set `ssl_ecdh_curve`, or enable FIPS mode, if NIST-only curves are required |
| Key derivation | HKDF over SHA-256 / SHA-384, bound to the negotiated suite; no separate MAC (`ism-1375`) |
| Certificate — lab | self-signed, `guac_cert_rsa_keylength` = **3072-bit RSA** (`ism-0476`, `ism-1765`), SHA-256 (`ism-1374`), SAN = proxy FQDN + host + IP |
| Certificate — prod | **Let's Encrypt** (`guac_tls_mode: letsencrypt`) or an **internal/evaluated CA** — the self-signed mode is for lab / behind-another-terminator use only (`ism-1324`) |
| Private key protection | nginx keys `root:root 0640` in `/etc/nginx/ssl/private`; guacd keys `guacd:guacd 0640` in `/etc/guacamole/ssl`. Logical access control only — the key files are **not** passphrase-encrypted and no HSM is used (`ism-1327`) |
| Internal guacd link | plaintext loopback by default (`ism-1781`); `guac_guacd_tls_enabled` wraps it in TLS 1.3 with a self-signed internal cert generated at **RSA-2048** — below the 3072-bit preference (`ism-1765`) `[raise if your profile requires it]` |
| Target-side encryption | RDP can use TLS/NLA and SSH is encrypted, but **VNC and telnet are not** (`ism-0469`) — scope those connections, or tunnel them |
| SSH | curated modern KEX (`curve25519-sha256`, `dh-group16-sha512`), ciphers (`aes256-gcm`, `chacha20-poly1305`), MACs (`hmac-sha2-512/256-etm`) (`ism-1769`) |
| Hashing | Guacamole stores password hashes as salted SHA-256 (upstream schema) — salted and hashed, not stretched (`ism-1402`) |
| Data at rest | backup bundles optionally AES-256 (`gpg -c`); the database itself is **not** encrypted at rest — full disk encryption is an OS-install decision (`ism-0459`) |

<a id="fips"></a>
### 7.4 Evaluated cryptography / FIPS

`guac_fips_enabled: true` (default **false**):

- RHEL: installs `crypto-policies-scripts`, runs `fips-mode-setup --enable`. **A reboot is
  required**; re-run `site.yml` afterwards to complete verification. Confirm with
  `fips-mode-setup --check`. This selects the RHEL FIPS 140-validated modules (kernel crypto,
  OpenSSL, GnuTLS, NSS) (`ism-0465`).
- Ubuntu needs Ubuntu Pro (`pro enable fips-updates`); Debian has no supported FIPS module — the
  task logs this and skips.
- Under FIPS the self-signed RSA-3072 keys remain compliant and the TLS group list narrows to the
  FIPS 186 curves P-256/P-384/P-521, which is what closes `ism-1446` / `ism-1761`. Verify the JVM
  uses a FIPS provider if that is in your scope `[decision: BouncyCastle FIPS / system NSS]`.
- **Do not enable FIPS on a host you cannot console into** — a failed transition can block SSH
  (`ism-1610`).

> **Note on `ism-0467`:** that control requires *ASD-approved High Assurance Cryptographic
> Equipment* for SECRET and TOP SECRET data and is **not** satisfied by FIPS mode. It is listed
> as out of scope in §12.1. The control this build bears on is `ism-0465` (evaluated
> cryptography for OFFICIAL: Sensitive / PROTECTED).

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

<a id="deploy"></a>
## 11. Deployment & change management

| Aspect | Design |
|---|---|
| Tool | Ansible (`ansible-core` ≥ 2.14), roles only, no shell install scripts |
| Invocation | `ansible-playbook -i inventory/hosts.ini site.yml` from `[the control node]` |
| Idempotence | a second run reports `changed=0`; verified in CI across the supported OS matrix (`test/run.sh`) |
| Secrets | Ansible Vault (`group_vars/vault.yml`); `[KMS/HSM integration if applicable]` |
| Air-gap | mirror `dnf`, `dlcdn.apache.org`, `archive.apache.org`, `repo1.maven.org`, EPEL/CRB internally; set `guac_apache_dl_base`, `guac_tomcat_dl_base`, `guac_mysql_connector_j_url`, `guac_jdbc_archive_url` and repo config accordingly |
| Container option | `container/Containerfile` + compose — same roles at build time (`guac_container_build=true`) |
| Change control | all changes are code in version control; peer-reviewed; applied via the pipeline; `[CAB reference]` (`ism-1816`, `ism-1422`) |
| Configuration baseline | `group_vars/all.yml` + `host_vars/[SYSTEM-NAME].yml` are the authoritative config record |
| Version register | every component version is pinned in `group_vars`; the host records what is installed in `/usr/local/.guacd_build_id`, `/etc/guacamole/.guac_schema_version` and each backup `MANIFEST` (`ism-1493`, `ism-1643`) |
| Artefact integrity | **gap** — tarballs are fetched over HTTPS from `dlcdn.apache.org` / `archive.apache.org` / Maven Central but their **GPG signatures and checksums are not verified**, and the EPEL / RPM Fusion release RPMs install with `disable_gpg_check: true` (`ism-1791`, `ism-1792`, `ism-0298`). Preferred fix: verify signatures once, then mirror internally and point `guac_apache_dl_base` at the mirror |
| Verification | every run ends with a live check — web app returns 200 and `guacadmin` obtains an API token; a second run reports `changed=0` (`ism-1037`, `ism-1636`) |

---

## 12. ISM control mapping

**Scope of this table:** the **165 controls** that this *component build* materially implements,
partly implements, deliberately does not address, or directly enables. It is **not** a full ISM
system security plan — the families listed in §12.1 are addressed by other artefacts.

**How rows were chosen.** Every control was selected by reading its actual statement against the
actual implementation (the Ansible roles, templates and systemd units in this repository), not by
keyword matching. A control earns a row only if its statement describes something this build
genuinely does, genuinely does not do, or directly enables — and every row's note cites concrete
evidence: a variable, a file, a unit directive or a verified behaviour. Where the build only
partly meets a control, the note says *which part is missing*. See `docs/ISM.md` for the full
methodology and the refresh procedure.

Status legend:

| | Meaning |
|---|---|
| ✅ **Implemented** | configured by default, or by a documented toggle |
| 🟡 **Partial** | implemented in part, or needs a variable set / an operational step |
| 📋 **Customer** | the design supports or enables it; an organisational process or another system must operate it |
| ❌ **Not addressed** | a real gap, called out honestly so it lands in the POA&M (§12.2) |

**Status breakdown:** ✅ 44 · 🟡 99 · 📋 16 · ❌ 6.

> **Dataset caveat.** Control statements are abridged from `docs/data/ism-controls.json`
> (retrieved **2026-09-11**), which is a **third-party community extract of the ISM, not an ACSC
> publication, and carries no ISM release label**. Treat the statements below as navigation aids,
> not as quotations. **The currently published ISM at cyber.gov.au is authoritative** — verify
> every control number, its text and its applicability to `[classification]` against it before an
> assessment. The *status and evidence note* in each row derive from this repository's code and
> hold regardless of ISM edition; only the numbering is at risk of drift. See `docs/ISM.md` §1.
>
> This table is generated — edit `docs/data/ism-mapping.yml` and run
> `python3 scripts/ism_map.py`; do not hand-edit the rows.

<!-- BEGIN ISM TABLE -->

#### System assurance, assessment and emergency access

| ISM control | Control statement (abridged from the dataset) | Status | Design reference | Coverage in this build |
|---|---|---|---|---|
| `ism-0041` | Systems have a system security plan that includes a description of the system and an annex that covers both applicable controls from this document and any additional controls that have been identified. | 📋 Customer | [§1 Purpose & scope](#scope) | This LLD is a component design intended to be annexed to the system security plan; the SSP and its full control annex remain an organisational artefact. |
| `ism-1564` | At the conclusion of a security assessment for a system, a plan of action and milestones is produced by the system owner. | 🟡 Partial | [§12.2 Residual actions (POA&M)](#poam) | §12.2 is a seeded plan of action and milestones covering every 🟡 and ❌ row in this table; the system owner produces the final POA&M after assessment. |
| `ism-1610` | A method of emergency access to systems is documented and tested at least once when initially implemented and each time fundamental information technology infrastructure changes occur. | 🟡 Partial | [§10 Backup & recovery](#backup) | Emergency access is console/SSH plus `guac-restore <bundle>` onto a freshly provisioned host; `test/dr.sh` exercises exactly that path. The FIPS task warns not to enable FIPS without console access. |
| `ism-1636` | System owners ensure controls for each system and its operating environment are assessed to determine if they have been implemented correctly and are operating as intended. | 🟡 Partial | [§11 Deployment & change management](#deploy) | `test/check.sh` (services, HTTPS login page, token auth), `test/dr.sh` (restore) and `test/upgrade.sh` (version bump) run in CI across the OS matrix; independent control assessment is still required. |
| `ism-principle-p3` | Systems and applications are designed and configured to reduce their attack surface. | ✅ Implemented | [§5.3 Application hardening](#app-hardening) | Single-purpose host: Tomcat docs/examples/host-manager/manager/ROOT webapps deleted, shutdown port set to -1, filesystem modules blacklisted, inbound limited to 22/80/443, all tiers bound to 127.0.0.1. |
| `ism-principle-p4` | Systems and applications are administered in a secure and accountable manner. | ✅ Implemented | [§6.3 Privileged access](#privileged) | The whole purpose of the component: administration is brokered through one authenticated, MFA-capable, logged and optionally recorded choke point instead of direct RDP/SSH. |

#### Jump-host / gateway and session brokering

| ISM control | Control statement (abridged from the dataset) | Status | Design reference | Coverage in this build |
|---|---|---|---|---|
| `ism-0619` | Users authenticate to other networks accessed via gateways. | ✅ Implemented | [§6.2 Authentication](#auth) | No target session can be opened until the user has authenticated to Guacamole and holds a READ permission on that connection; site.yml verifies token auth on every run. |
| `ism-0631` | Gateways only allow explicitly authorised data flows. | 🟡 Partial | [§2 Architecture overview](#arch) | Guacamole brokers only the connections declared in `guac_connections` (deny-by-default permissions); docs/FIREWALL.md is the authorised-flow matrix the surrounding network must enforce. |
| `ism-1037` | Gateways undergo testing following configuration changes, and at regular intervals no more than six months apart, to validate they conform to expected security configurations. | 🟡 Partial | [§11 Deployment & change management](#deploy) | Every `site.yml` run re-asserts the full configuration and ends with a live login test; a second run reports changed=0. A scheduled OpenSCAP benchmark run is the remaining half (see roles/cis). |
| `ism-1192` | Gateways inspect and filter data flows at the transport and above network layers. | ✅ Implemented | [§2 Architecture overview](#arch) | A genuine application-layer protocol break: nginx terminates HTTPS, Tomcat handles the Guacamole protocol, guacd re-originates RDP/SSH/VNC from its own stack. No client packet is forwarded to a target. |
| `ism-1385` | Administrative infrastructure is segregated from the wider network and the internet. | 🟡 Partial | [§4 Network & firewall design](#net) | firewalld is default-deny inbound and the design places the host in a dedicated broker zone; egress to package mirrors is expected only during build windows (air-gap uses an internal mirror). |
| `ism-1387` | Administrative activities are conducted through jump servers. | ✅ Implemented | [§6.3 Privileged access](#privileged) | This build *is* the jump server. Administrators authenticate to Guacamole and every RDP/SSH/VNC session to a target is brokered by guacd — no direct administrative path to targets is required. |
| `ism-1388` | Only jump servers can communicate with assets requiring administrative activities to be performed. | 🟡 Partial | [§4 Network & firewall design](#net) | The host originates all target traffic (docs/FIREWALL.md flows O1–O5, scoped per connection); enforcing that *only* the broker may reach targets is a network ACL change, not a host setting. |
| `ism-1774` | Gateways are managed via a secure path isolated from all connected networks. | 🟡 Partial | [§4 Network & firewall design](#net) | Management is SSH/22 from the Ansible control node or bastion only (flow I3), hardened by /etc/ssh/sshd_config.d/50-guac-hardening.conf; isolating that path is a network-design step. |
| `ism-1863` | Networked management interfaces for ICT equipment are not directly exposed to the internet. | 🟡 Partial | [§4 Network & firewall design](#net) | Tomcat 8080 is closed in firewalld when the proxy is enabled, the Tomcat shutdown port is disabled, MariaDB binds loopback/socket only; exposure of 22/443 to the internet is a perimeter decision. |

#### Network design, firewalling and segregation

| ISM control | Control statement (abridged from the dataset) | Status | Design reference | Coverage in this build |
|---|---|---|---|---|
| `ism-0385` | Servers maintain effective functional separation with other servers allowing them to operate independently. | 🟡 Partial | [§2 Architecture overview](#arch) | The host is single-purpose and self-contained (local MariaDB by default), so it operates independently of other servers; with `guac_install_mariadb: false` it depends on the nominated DB server. |
| `ism-0521` | IPv6 functionality is disabled in dual-stack network devices unless it is being used. | 🟡 Partial | [§4 Network & firewall design](#net) | IPv6 is not disabled — nginx listens on [::]:80 and [::]:443. The sysctl set disables IPv6 redirects and source routing. Disable IPv6 in the OS build if it is genuinely unused. |
| `ism-1006` | Security measures are implemented to prevent unauthorised access to network management traffic. | 🟡 Partial | [§4 Network & firewall design](#net) | Management traffic is SSH only, with curated ciphers/KEX/MACs, root login denied and (at L2) TCP/agent forwarding disabled; restricting the source of that traffic is a network control. |
| `ism-1181` | Networks are segregated into multiple network zones according to the criticality of servers, services and data. | 📋 Customer | [§4 Network & firewall design](#net) | The design assumes a dedicated broker zone between the client and target zones; creating the zones is a network-design activity outside this playbook. |
| `ism-1182` | Network access controls are implemented to limit network traffic within and between network segments to only those required for business purposes. | 🟡 Partial | [§4 Network & firewall design](#net) | The host firewall limits ingress to 22/80/443 and closes 8080 behind the proxy; inter-segment enforcement (client→broker, broker→target) must be implemented from docs/FIREWALL.md. |
| `ism-1416` | A software firewall is implemented on workstations and servers to restrict inbound and outbound network connections to an organisation-approved set of applications and services. | 🟡 Partial | [§4 Network & firewall design](#net) | firewalld (RHEL) / ufw (Debian) restrict *inbound* connections to an approved set. Outbound egress filtering is not configured by `guac_manage_firewall` — apply it upstream or extend the zone. |
| `ism-1427` | Gateways perform ingress traffic filtering to detect and prevent IP source address spoofing. | 🟡 Partial | [§5.2 OS hardening](#hardening) | `net.ipv4.conf.all/default.rp_filter=1` plus `log_martians=1` give host-level anti-spoofing; ingress filtering at the gateway itself is a network responsibility. |
| `ism-1479` | Servers minimise communications with other servers at both the network and file system level. | 🟡 Partial | [§2 Architecture overview](#arch) | All inter-tier traffic (nginx→Tomcat→guacd→MariaDB) stays on 127.0.0.1; the only server-to-server flows leaving the host are DNS, NTP, the SIEM, optional LDAP/Duo and the brokered target sessions. |

#### Operating system hardening and secure configuration

| ISM control | Control statement (abridged from the dataset) | Status | Design reference | Coverage in this build |
|---|---|---|---|---|
| `ism-0343` | If there is no business requirement for writing to removable media and devices, such functionality is disabled via the use of device access control software or by disabling external communication interfaces. | ✅ Implemented | [§5.2 OS hardening](#hardening) | At `guac_hardening_level: l2` the usb-storage module is blacklisted via /etc/modprobe.d/90-guac-hardening.conf (`install usb-storage /bin/false`), removing write access to removable media. |
| `ism-0380` | Unneeded accounts, components, services and functionality of operating systems are disabled or removed. | 🟡 Partial | [§5.2 OS hardening](#hardening) | Unused filesystem modules (cramfs, freevxfs, jffs2, hfs, hfsplus, squashfs, udf) and usb-storage at L2 are blacklisted, ctrl-alt-del is masked and core dumps disabled; base-image service minimisation is the SOE's job. |
| `ism-0383` | Default accounts or credentials for operating systems, including for any pre-configured accounts, are changed. | 🟡 Partial | [§5.2 OS hardening](#hardening) | guacd/tomcat/nginx run as system accounts with /sbin/nologin and locked passwords; the Guacamole `guacadmin` default is flagged for mandatory change at first login but is not force-rotated by the playbook. |
| `ism-1034` | A HIPS is implemented on critical servers and high-value servers. | ❌ Not addressed | [§5.2 OS hardening](#hardening) | No HIPS is deployed. SELinux is left enforcing (mandatory access control) and auditd is installed, but neither is a host-based intrusion prevention system. |
| `ism-1407` | The latest release, or the previous release, of operating systems are used. | 🟡 Partial | [§5.1 Build & SOE](#os-build) | The supported matrix is RHEL/Oracle/Rocky/Alma 9–10, Debian 12–13, Ubuntu 22.04/24.04/26.04 — current or previous release. Tracking minor-release currency is an operational task. |
| `ism-1409` | ACSC and vendor hardening guidance for operating systems is implemented. | 🟡 Partial | [§5.2 OS hardening](#hardening) | roles/hardening applies a CIS-aligned baseline (sysctl, module blacklist, core dumps, login.defs, file modes, cron/at restriction, ctrl-alt-del masked, SELinux left enforcing). Full CIS L2 + OpenSCAP is roles/cis. |
| `ism-1417` | Antivirus software is implemented on workstations and servers with: signature-based detection functionality enabled and set to a high level; heuristic-based detection functionality enabled and set to a high level; reputation rating functionality enabled; ransomware protection functionality enabled … | ❌ Not addressed | [§5.2 OS hardening](#hardening) | No antivirus/EDR agent is installed by this build. Deploy the organisation's server agent alongside it — the playbook does not conflict with one. |
| `ism-1418` | If there is no business requirement for reading from removable media and devices, such functionality is disabled via the use of device access control software or by disabling external communication interfaces. | ✅ Implemented | [§5.2 OS hardening](#hardening) | Same control: the usb-storage blacklist at L2 removes read access to removable media on a host that has no business requirement for it. |
| `ism-1492` | Operating system exploit protection functionality is enabled. | 🟡 Partial | [§5.2 OS hardening](#hardening) | The Linux equivalents are set: `kernel.randomize_va_space=2` (ASLR), `kptr_restrict=2`, `dmesg_restrict=1`, `yama.ptrace_scope=1`, `fs.suid_dumpable=0`, `protected_hardlinks/symlinks=1`. |
| `ism-1501` | Operating systems that are no longer supported by vendors are replaced. | ✅ Implemented | [§5.1 Build & SOE](#os-build) | site.yml asserts a supported platform before any role runs (RHEL family major 9/10, or Debian family) and fails the play otherwise, so the build cannot land on an out-of-support major. |
| `ism-1584` | Unprivileged users are prevented from bypassing, disabling or modifying security functionality of operating systems. | 🟡 Partial | [§5.2 OS hardening](#hardening) | Unprivileged users cannot alter security functionality: shadow/gshadow 0000, sshd_config 0600, crontab 0600, cron.allow/at.allow restrict scheduling to root, SELinux stays enforcing, auditd watches the config paths. |
| `ism-1592` | Unprivileged users do not have the ability to install unapproved software. | 🟡 Partial | [§5.2 OS hardening](#hardening) | Package installation requires root and service accounts are nologin, so unprivileged users cannot install software; there is no execution allow-listing (fapolicyd) to stop a user running a downloaded binary. |
| `ism-1745` | Early Launch Antimalware, Secure Boot, Trusted Boot and Measured Boot functionality is enabled. | ❌ Not addressed | [§5.1 Build & SOE](#os-build) | Secure Boot / Measured Boot are firmware-and-image properties set at OS install; this playbook neither enables nor verifies them. Confirm at build time and record the result. |

#### Server application hardening (Tomcat, nginx, guacd, MariaDB)

| ISM control | Control statement (abridged from the dataset) | Status | Design reference | Coverage in this build |
|---|---|---|---|---|
| `ism-0304` | Applications that are no longer supported by vendors are removed. | 🟡 Partial | [§8 Patch & vulnerability management](#patching) | Superseded Guacamole artefacts are pruned automatically on a version bump; deciding that a component has reached vendor end-of-support, and removing it, remains an operational judgement. |
| `ism-1245` | All temporary installation files and logs created during server application installation processes are removed after server applications have been installed. | 🟡 Partial | [§3.1 Guacamole server (guacd)](#guacd) | guacd is compiled on the host, so the source tree and build toolchain remain under /usr/local/src/guacamole after install. The container variant drops them; on a VM, decide whether to remove them post-build. |
| `ism-1246` | ACSC and vendor hardening guidance for server applications is implemented. | 🟡 Partial | [§5.3 Application hardening](#app-hardening) | A curated subset of vendor guidance is applied: Tomcat shutdown port disabled and ErrorReportValve locked down, nginx `server_tokens off` plus security headers, MariaDB secure-installation equivalent. Not a full vendor benchmark pass. |
| `ism-1247` | Unneeded accounts, components, services and functionality of server applications are disabled or removed. | ✅ Implemented | [§5.3 Application hardening](#app-hardening) | Tomcat docs/examples/host-manager/manager/ROOT webapps are deleted and the shutdown port set to -1; MariaDB anonymous users and the `test` database are removed; extension jars for disabled features are pruned on every run. |
| `ism-1249` | Server applications are configured to run as a separate account with the minimum privileges needed to perform their functions. | ✅ Implemented | [§5.3 Application hardening](#app-hardening) | guacd runs as the dedicated `guacd` system account, Tomcat as `tomcat`, nginx as its packaged user — all system accounts, /sbin/nologin, password-locked, and guacd is additionally denied cron. |
| `ism-1250` | The accounts under which server applications run have limited access to their underlying server’s file system. | 🟡 Partial | [§3.1 Guacamole server (guacd)](#guacd) | guacd.service sets NoNewPrivileges=true, ProtectSystem=full and a private RuntimeDirectory, with a 0700 home for FreeRDP certificate state. tomcat.service carries no equivalent sandboxing directives yet. |
| `ism-1260` | Default accounts or credentials for server applications, including for any pre-configured accounts, are changed. | 🟡 Partial | [§6.2 Authentication](#auth) | Tomcat ships no default users (the manager webapps are removed), MariaDB anonymous accounts are deleted and root is unix_socket-only locally; the Guacamole `guacadmin`/`guacadmin` default must be changed by the operator. |
| `ism-1263` | Unique privileged accounts are used for administering individual server applications. | 🟡 Partial | [§6.3 Privileged access](#privileged) | Application administration is separate from OS administration: Guacamole admins hold ADMINISTER in the app, the DB account holds DML on one schema only, and host administration is a named sudo account. |
| `ism-1483` | The latest release of internet-facing server applications are used. | 🟡 Partial | [§8 Patch & vulnerability management](#patching) | Versions are pinned in group_vars (`guac_version`, `guac_tomcat_version`, `guac_mysql_connector_j_version`) and a bump plus one re-run performs the upgrade; tracking upstream releases is an operational task. |
| `ism-1704` | Internet-facing services, office productivity suites, web browsers and their extensions, email clients, PDF software, Adobe Flash Player, and security products that are no longer supported by vendors are removed. | 🟡 Partial | [§8 Patch & vulnerability management](#patching) | The upgrade path removes the superseded war, the exploded webapp, the Tomcat work cache and stale-version extension jars, so an unsupported Guacamole build cannot be left loadable on disk. |

#### Web application security

| ISM control | Control statement (abridged from the dataset) | Status | Design reference | Coverage in this build |
|---|---|---|---|---|
| `ism-1278` | Web applications are designed or configured to provide as little error information as possible about the structure of databases. | ✅ Implemented | [§3.4 Web application & reverse proxy](#web) | Tomcat's ErrorReportValve runs with showReport=false and showServerInfo=false, and nginx sets `server_tokens off`, so neither stack traces nor version/schema detail reach the browser. |
| `ism-1424` | Web applications implement Content-Security-Policy, HSTS and X-Frame-Options via security policy in response headers. | ✅ Implemented | [§3.4 Web application & reverse proxy](#web) | nginx adds Content-Security-Policy (`guac_proxy_csp`), Strict-Transport-Security (2 years, includeSubDomains) and X-Frame-Options SAMEORIGIN on every response, plus nosniff, Referrer-Policy and Permissions-Policy. |
| `ism-1536` | The following events are logged for web applications: attempted access that is denied, crashes and error messages, and search queries initiated by users. | 🟡 Partial | [§3.4 Web application & reverse proxy](#web) | nginx access and error logs record requests, denied access and errors, with the real client IP restored by Tomcat's RemoteIpValve; Tomcat/Guacamole log auth failures. Central storage needs `guac_syslog_target`. |
| `ism-1552` | All web application content is offered exclusively using HTTPS. | ✅ Implemented | [§3.4 Web application & reverse proxy](#web) | Port 80 serves only `return 301 https://$host$request_uri`; all Guacamole content and the WebSocket tunnel are served from the TLS 1.3 vhost. |
| `ism-1817` | Authentication and authorisation of clients is performed when clients call web APIs that facilitate access to data not authorised for release into the public domain. | ✅ Implemented | [§3.2 Guacamole web application](#webapp) | Guacamole's REST API requires an auth token for every call; the roles/connections reconcile module obtains one via /api/tokens and all object reads are permission-filtered per user. |
| `ism-1818` | Authentication and authorisation of clients is performed when clients call web APIs that facilitate modification of data. | ✅ Implemented | [§3.2 Guacamole web application](#webapp) | The same token plus the user's system/object permissions gate every mutating API call — creating connections or users requires ADMINISTER or an explicit CREATE_* permission. |

#### Database systems

| ISM control | Control statement (abridged from the dataset) | Status | Design reference | Coverage in this build |
|---|---|---|---|---|
| `ism-1255` | Database users’ ability to access, insert, modify and remove database contents is restricted based on their work duties. | ✅ Implemented | [§3.3 Database](#db) | `guacamole_user` is granted SELECT, INSERT, UPDATE, DELETE on `guacamole_db.*` and nothing else — no DDL, no access to other schemas, no administrative privileges. |
| `ism-1256` | File-based access controls are applied to database files. | 🟡 Partial | [§3.3 Database](#db) | The MariaDB data directory keeps the distribution's packaged ownership and mode (mysql:mysql, 0750); guacamole.properties, which holds the DB password, is 0640 root:tomcat. The datadir mode is not asserted by the playbook. |
| `ism-1268` | The need-to-know principle is enforced for database contents through the application of minimum privileges, database views and database roles. | 🟡 Partial | [§6.1 Access control & sessions](#access) | Need-to-know is enforced at the application layer — Guacamole grants per-connection/per-group READ permissions and shows a user nothing else. Database-level roles and views are not used. |
| `ism-1269` | Database servers and web servers are functionally separated. | 🟡 Partial | [§3.3 Database](#db) | `guac_install_mariadb: false` plus `guac_mysql_host` places the database on a separate server; the single-host default deliberately co-locates them for a small deployment. |
| `ism-1270` | Database servers are placed on a different network segment to user workstations. | 📋 Customer | [§3.3 Database](#db) | When a remote database is used, placing it on a server segment (never a user segment) is a network-design decision; the playbook only needs TCP 3306 reachability from the broker. |
| `ism-1271` | Network access controls are implemented to restrict database server communications to strictly defined network resources, such as web servers, application servers and storage area networks. | 🟡 Partial | [§3.3 Database](#db) | The only client of the database is this host; restrict the DB listener to the broker's address (flow O6 in docs/FIREWALL.md). Locally the listener is not exposed at all. |
| `ism-1272` | If only local access to a database is required, networking functionality of database management system software is disabled or directed to listen solely to the localhost interface. | ✅ Implemented | [§3.3 Database](#db) | The default local deployment reaches MariaDB over the UNIX socket / 127.0.0.1 only — JDBC traffic never touches a routable interface, and 3306 is not opened in firewalld. |
| `ism-1276` | Parameterised queries or stored procedures, instead of dynamically generated queries, are used for database interactions. | 🟡 Partial | [§3.3 Database](#db) | All database interaction is upstream Guacamole's JDBC extension, which uses MyBatis prepared statements; this is an upstream property the build inherits, not something configured here. |
| `ism-1277` | Data communicated between database servers and web servers is encrypted. | 🟡 Partial | [§3.3 Database](#db) | Local traffic is loopback-only, so no network encryption applies. For a remote database, enable TLS at the DBMS and add `mysql-ssl-mode`/`mysql-ssl-*` to guacamole.properties — not automated here. |
| `ism-1537` | The following events are logged for databases: access or modification of particularly important content; addition of new users, especially privileged users; changes to user roles or privileges; attempts to elevate user privileges; queries containing comments; queries containing multiple embedded … | 🟡 Partial | [§3.3 Database](#db) | Guacamole logs user, permission and connection changes at the application layer, but the MariaDB audit plugin / general log is NOT enabled by this build — turn on server_audit if DB-level event logging is in scope. |
| `ism-1758` | Database event logs are stored centrally. | 🟡 Partial | [§3.3 Database](#db) | MariaDB error (and any enabled general/slow) logs are forwarded by rsyslog once `guac_syslog_target` is set; until then they stay under /var/log/mariadb. |
| `ism-1853` | Privileged access to data repositories is limited to only what is required for users and services to undertake their duties. | 🟡 Partial | [§3.3 Database](#db) | The application account holds DML only; MariaDB root is reachable locally via unix_socket authentication with no stored password, so privileged DB access requires root on the host. |

#### Cryptographic fundamentals, TLS and certificates

| ISM control | Control statement (abridged from the dataset) | Status | Design reference | Coverage in this build |
|---|---|---|---|---|
| `ism-0459` | Full disk encryption, or partial encryption where access controls will only allow writing to the encrypted partition, is implemented when encrypting data at rest. | 📋 Customer | [§5.1 Build & SOE](#os-build) | Full disk encryption is an OS-install / platform decision (LUKS, or the hypervisor's storage encryption) — this playbook neither configures nor verifies it. The database and its credentials sit on that disk. |
| `ism-0465` | Cryptographic equipment or software that has completed a Common Criteria evaluation against a Protection Profile is used to protect OFFICIAL: Sensitive or PROTECTED data when communicated over insufficiently secure networks, outside of appropriately secure areas or via public network infrastructure. | 🟡 Partial | [§7.4 Evaluated cryptography / FIPS](#fips) | `guac_fips_enabled: true` runs `fips-mode-setup --enable`, selecting the platform's FIPS 140 validated modules (kernel, OpenSSL, GnuTLS, NSS). Off by default; needs a reboot; confirm the JVM's provider separately. |
| `ism-0469` | An ASD-Approved Cryptographic Protocol (AACP) or high assurance cryptographic protocol is used to protect data when communicated over network infrastructure. | 🟡 Partial | [§7 Cryptography](#crypto) | Client→broker is TLS 1.3, broker→SIEM is TLS/RELP-TLS, broker→AD is LDAPS. Broker→target depends on the protocol: RDP can use TLS/NLA, SSH is encrypted, but VNC and telnet are not — scope those connections accordingly. |
| `ism-0476` | When using RSA for digital signatures, and passing encryption session keys or similar keys, a modulus of at least 2048 bits is used, preferably 3072 bits. | ✅ Implemented | [§7 Cryptography](#crypto) | `guac_cert_rsa_keylength` defaults to 3072, the preferred modulus rather than the 2048-bit minimum, for the proxy certificate. |
| `ism-1139` | Only the latest version of TLS is used for TLS connections. | ✅ Implemented | [§7 Cryptography](#crypto) | `ssl_protocols TLSv1.3` only (`guac_proxy_ssl_protocols`) — TLS 1.2 and below are not offered at all, so there is no version-downgrade path. |
| `ism-1324` | Certificates are generated using an evaluated certificate authority or hardware security module. | 🟡 Partial | [§7 Cryptography](#crypto) | Production should use `guac_tls_mode: letsencrypt` or a certificate from an internal/evaluated CA; the built-in self-signed mode exists for lab use or where another terminator fronts the service. |
| `ism-1327` | Certificates are protected by encryption, user authentication, and both logical and physical access controls. | 🟡 Partial | [§7 Cryptography](#crypto) | Private keys are 0640 root:root under /etc/nginx/ssl/private (guacd keys 0640 guacd:guacd), so logical access control is in place — but the key files themselves are not passphrase-encrypted and no HSM is used. |
| `ism-1369` | AES-GCM is used for encryption of TLS connections. | ✅ Implemented | [§7 Cryptography](#crypto) | TLS 1.3's cipher suite set is AEAD-only: AES-128/256-GCM and ChaCha20-Poly1305. No CBC or stream suites can be negotiated. |
| `ism-1370` | Only server-initiated secure renegotiation is used for TLS connections. | ✅ Implemented | [§7 Cryptography](#crypto) | TLS 1.3 removes renegotiation from the protocol entirely; post-handshake key update is server- or client-initiated within the established, authenticated session. |
| `ism-1374` | SHA-2-based certificates are used for TLS connections. | ✅ Implemented | [§7 Cryptography](#crypto) | Self-signed certificates are generated by `openssl req -x509` with the OpenSSL default SHA-256 signature; Let's Encrypt (`guac_tls_mode: letsencrypt`) also issues SHA-256. |
| `ism-1375` | SHA-2 is used for the Hash-based Message Authentication Code (HMAC) and pseudorandom function (PRF) for TLS connections. | ✅ Implemented | [§7 Cryptography](#crypto) | TLS 1.3 derives all traffic keys with HKDF over SHA-256 or SHA-384 (bound to the negotiated suite) and has no separate MAC — SHA-1 based PRFs are not reachable. |
| `ism-1446` | When using elliptic curve cryptography, a curve from FIPS 186-4 is used. | 🟡 Partial | [§7.4 Evaluated cryptography / FIPS](#fips) | Under `guac_fips_enabled` the platform crypto policy restricts TLS to FIPS 186 curves (P-256/P-384/P-521). Outside FIPS mode OpenSSL's default group list leads with X25519, which is not a FIPS 186 curve. |
| `ism-1448` | When using DH or ECDH for key establishment of TLS connections, the ephemeral variant is used. | ✅ Implemented | [§7 Cryptography](#crypto) | TLS 1.3 mandates ephemeral (EC)DHE key establishment; static DH/ECDH key exchange was removed from the protocol. |
| `ism-1453` | Perfect Forward Secrecy (PFS) is used for TLS connections. | ✅ Implemented | [§7 Cryptography](#crypto) | A direct consequence of ephemeral-only key establishment: every TLS 1.3 session to the proxy has perfect forward secrecy. `ssl_session_tickets off` also prevents ticket-key reuse across restarts. |
| `ism-1553` | TLS compression is disabled for TLS connections. | ✅ Implemented | [§7 Cryptography](#crypto) | TLS 1.3 removed protocol-level compression (the CRIME mitigation); nginx enables no TLS compression of its own. |
| `ism-1761` | When using ECDH for agreeing on encryption session keys, NIST P-256, P-384 or P-521 curves are used, preferably the NIST P-384 curve. | 🟡 Partial | [§7 Cryptography](#crypto) | P-256 and P-384 are offered, but X25519 is preferred by OpenSSL's default TLS 1.3 group order. Set `ssl_ecdh_curve` (or enable FIPS mode) if your profile requires NIST curves exclusively. |
| `ism-1765` | When using RSA for digital signatures, and passing encryption session keys or similar keys, a modulus of at least 3072 bits is used, preferably 3072 bits. | 🟡 Partial | [§7 Cryptography](#crypto) | The proxy certificate is RSA-3072 by default, but the optional internal guacd certificate (`guac_guacd_tls_enabled`) is generated at rsa:2048 in roles/hardening/tasks/app_layer.yml — loopback-only, but raise it if 3072 is required everywhere. |
| `ism-1769` | When using AES for encryption, AES-128, AES-192 or AES-256 is used, preferably AES-256. | ✅ Implemented | [§7 Cryptography](#crypto) | AES-256 is used where the build chooses: backup bundles are `gpg -c --cipher-algo AES256`, SSH leads with aes256-gcm. TLS 1.3 may still negotiate TLS_AES_128_GCM_SHA256 — constrain the crypto policy if AES-192+ is mandated. |
| `ism-1781` | All data communicated over network infrastructure is encrypted. | 🟡 Partial | [§7 Cryptography](#crypto) | Honest gap: the guacd↔Tomcat link is plaintext on loopback unless `guac_guacd_tls_enabled` is set, and VNC/telnet target sessions carry no transport encryption of their own. |

#### Secure Shell

| ISM control | Control statement (abridged from the dataset) | Status | Design reference | Coverage in this build |
|---|---|---|---|---|
| `ism-0484` | The SSH daemon is configured to: only listen on the required interfaces (ListenAddress xxx.xxx.xxx.xxx); have a suitable login banner (Banner x); have a login authentication timeout of no more than 60 seconds (LoginGraceTime 60); disable host-based authentication (HostbasedAuthentication no) … | 🟡 Partial | [§5.2 OS hardening](#hardening) | The drop-in sets LoginGraceTime 60, Banner /etc/issue.net, HostbasedAuthentication no, IgnoreRhosts yes, PermitRootLogin no, PermitEmptyPasswords no, X11Forwarding no and (at L2) AllowTcpForwarding no. Not set: ListenAddress, GatewayPorts no. |
| `ism-0485` | Public key-based authentication is used for SSH connections. | 🟡 Partial | [§5.2 OS hardening](#hardening) | Key-only SSH is one variable: `guac_hardening_ssh_password_auth: false` writes PasswordAuthentication no and KbdInteractiveAuthentication no. The default leaves password auth enabled so a build cannot lock itself out. |
| `ism-0487` | When using logins without a passphrase for SSH connections, the following are disabled: access from IP addresses that do not require access; port forwarding; agent credential forwarding; X11 display remoting; console access. | ✅ Implemented | [§5.2 OS hardening](#hardening) | At `guac_hardening_level: l2` the drop-in sets AllowTcpForwarding no, AllowAgentForwarding no and X11Forwarding no, so a passphrase-less key cannot be used to tunnel or forward credentials. |
| `ism-0489` | When SSH-agent or similar key caching programs are used, it is limited to workstations and servers with screen locks and key caches that are set to expire within four hours of inactivity. | 🟡 Partial | [§5.2 OS hardening](#hardening) | AllowAgentForwarding no at L2 stops agent credentials being forwarded into this host; the cache expiry policy on the administrator's own workstation is outside this build. |
| `ism-1449` | SSH private keys are protected with a passphrase or a key encryption key. | 📋 Customer | [§5.2 OS hardening](#hardening) | The host never holds an administrator's SSH private key — keys live on the control node or the administrator's workstation, where passphrase protection is enforced by process. |
| `ism-1506` | The use of SSH version 1 is disabled for SSH connections. | ✅ Implemented | [§5.2 OS hardening](#hardening) | Every supported platform ships OpenSSH 8.x/9.x, which has no SSH-1 implementation to enable; the curated Ciphers/KexAlgorithms/MACs lists are SSH-2 only. |

#### Identification, authentication and multi-factor authentication

| ISM control | Control statement (abridged from the dataset) | Status | Design reference | Coverage in this build |
|---|---|---|---|---|
| `ism-0414` | Personnel granted access to a system and its resources are uniquely identifiable. | 🟡 Partial | [§6.2 Authentication](#auth) | Each person gets their own Guacamole account (`guac_users`) or a directory/SSO identity; connection history, recordings and nginx logs attribute every session to that identity. |
| `ism-0415` | The use of shared user accounts is strictly controlled, and personnel using such accounts are uniquely identifiable. | 🟡 Partial | [§6.2 Authentication](#auth) | Target-host credentials stored in a connection are effectively shared, but the *person* remains uniquely identified: Guacamole records who opened which connection, and `guac_histrec_enabled` records the session itself. |
| `ism-0418` | Credentials are kept separate from systems they are used to authenticate to, except for when performing authentication activities. | 🟡 Partial | [§6.2 Authentication](#auth) | Inherent to credential brokering: target credentials live in the Guacamole database on the broker. Mitigated by loopback-only DB, 0640 guacamole.properties and encrypted backups; avoid it with RDP/SSH credential pass-through or per-user prompting. |
| `ism-0421` | Passphrases used for single-factor authentication are at least 4 random words with a total minimum length of 14 characters, unless more stringent requirements apply. | 📋 Customer | [§6.2 Authentication](#auth) | Guacamole core enforces no passphrase length or composition policy. Enforce it at the directory/IdP (LDAP, OIDC, SAML) or accept the risk and record where the policy is applied. |
| `ism-0974` | Multi-factor authentication is used to authenticate unprivileged users of systems. | 🟡 Partial | [§6.2 Authentication](#auth) | `guac_totp_enabled` or `guac_duo_enabled` adds a second factor for all users; both are off by default and must be enabled per deployment. SSO (OIDC/SAML/CAS) can instead delegate MFA to the IdP. |
| `ism-1173` | Multi-factor authentication is used to authenticate privileged users of systems. | 🟡 Partial | [§6.2 Authentication](#auth) | The same TOTP/Duo extension applies to administrative Guacamole users — Guacamole has no way to exempt an account from an installed MFA extension. |
| `ism-1401` | Multi-factor authentication uses either: something users have and something users know, or something users have that is unlocked by something users know or are. | 🟡 Partial | [§6.2 Authentication](#auth) | TOTP (something you have, in an enrolled authenticator) or Duo push combines with the memorised secret; `guac_ssl_auth_enabled` gives a certificate/smart-card factor instead. |
| `ism-1402` | Credentials stored on systems are protected by a password manager; a hardware security module; or by salting, hashing and stretching them before storage within a database. | 🟡 Partial | [§6.2 Authentication](#auth) | Guacamole stores per-user password hashes salted with SHA-256 (upstream schema) — salted and hashed, but not stretched. Target-host credentials in connection parameters are stored recoverable; see ism-0418. |
| `ism-1403` | Accounts, except for break glass accounts, are locked out after a maximum of five failed logon attempts. | ❌ Not addressed | [§6.2 Authentication](#auth) | Neither Guacamole nor this playbook implements lockout: pam_faillock is not configured (auditd only watches /var/run/faillock) and Guacamole core has no lockout. Add fail2ban against the Guacamole auth log — see roles/cis for PAM faillock. |
| `ism-1504` | Multi-factor authentication is used by an organisation’s users if they authenticate to their organisation’s internet-facing services. | 🟡 Partial | [§6.2 Authentication](#auth) | For an internet-facing deployment, enable TOTP/Duo, or front the service with an IdP via `guac_openid_enabled` / `guac_saml_enabled` and enforce MFA there. |
| `ism-1505` | Multi-factor authentication is used to authenticate users accessing important data repositories. | 🟡 Partial | [§6.2 Authentication](#auth) | Guacamole is the access path to the target estate, so MFA at the broker gates access to everything behind it — provided one of the MFA/SSO toggles is enabled. |
| `ism-1546` | Users are authenticated before they are granted access to a system and its resources. | ✅ Implemented | [§6.2 Authentication](#auth) | Guacamole authenticates every user before any resource is visible; site.yml's final smoke test proves the auth path works by requesting an API token on every run. |
| `ism-1595` | Credentials provided to users are changed on first use. | 🟡 Partial | [§6.2 Authentication](#auth) | Guacamole supports an 'expired' password attribute that forces a change at next login, and the default `guacadmin` credential is documented as change-on-first-login; the playbook does not set the flag for you. |
| `ism-1603` | Authentication methods susceptible to replay attacks are disabled. | 🟡 Partial | [§6.2 Authentication](#auth) | Host-based and rhosts SSH authentication are disabled; SAML runs with `saml-strict: true` (signature validation) and OIDC validates the nonce against `openid-max-nonce-validity`; TOTP codes are single-use within their window. |
| `ism-1682` | Multi-factor authentication is phishing-resistant. | 🟡 Partial | [§6.2 Authentication](#auth) | TOTP is not phishing-resistant. Phishing-resistant paths exist in this build: `guac_ssl_auth_enabled` (X.509 client certificate / smart card) or OIDC/SAML to an IdP enforcing WebAuthn/FIDO2. |
| `ism-1685` | Credentials for break glass accounts, local administrator accounts and service accounts are long, unique, unpredictable and managed. | 🟡 Partial | [§6.2 Authentication](#auth) | guacd/tomcat are password-locked system accounts with no usable credential at all, and DB/LDAP/Duo/SSO secrets are supplied per deployment through Ansible Vault. The shipped `ChangeMe_*` defaults in group_vars must be overridden. |

#### Access control, sessions and account management

| ISM control | Control statement (abridged from the dataset) | Status | Design reference | Coverage in this build |
|---|---|---|---|---|
| `ism-0407` | A secure record is maintained for the life of each system covering: all personnel authorised to access the system, and their user identification; who provided authorisation for access; when access was granted; the level of access that was granted; when access, and the level of access, was last … | 🟡 Partial | [§6.1 Access control & sessions](#access) | `guac_users` / `guac_user_groups` in version control is an auditable record of who holds what access and when it changed (git history); authoriser, grant date and review dates belong in the IDAM register. |
| `ism-0408` | Systems have a logon banner that requires users to acknowledge and accept their security responsibilities before access is granted. | 🟡 Partial | [§6.1 Access control & sessions](#access) | The SSH drop-in sets `Banner /etc/issue.net`, but this playbook does not write the banner text — supply your approved wording. Guacamole's login page has no banner facility. |
| `ism-0428` | Systems are configured with a session or screen lock that: activates after a maximum of 15 minutes of user inactivity, or if manually activated by users; conceals all session content on the screen; ensures that the screen does not enter a power saving state before the session or screen lock is … | 🟡 Partial | [§6.1 Access control & sessions](#access) | `guac_session_timeout_minutes` (default 15) sets `api-session-timeout`, terminating an idle web session inside the 15-minute limit. OS console/screen lock does not apply to a headless server. |
| `ism-0430` | Access to systems, applications and data repositories is removed or suspended on the same day personnel no longer have a legitimate requirement for access. | 📋 Customer | [§6.2 Authentication](#auth) | With LDAP or SSO enabled, disabling the directory account removes access immediately. For database-only auth, remove the user from `guac_users` and re-run with `guac_connections_prune: true`. |
| `ism-0432` | Access requirements for a system and its resources are documented in its system security plan. | 🟡 Partial | [§6.1 Access control & sessions](#access) | §6.1 and the declarative `guac_users`/`guac_user_groups`/`guac_connections` data document the access model for this component; the system security plan carries the authoritative statement. |
| `ism-0853` | On a daily basis, outside of business hours and after an appropriate period of inactivity, user sessions are terminated and workstations are restarted. | 🟡 Partial | [§6.1 Access control & sessions](#access) | Idle Guacamole sessions are terminated by `api-session-timeout`; scheduled daily session termination and host restart are not implemented and would be an operational job if required. |
| `ism-1404` | Unprivileged access to systems and applications is automatically disabled after 45 days of inactivity. | 📋 Customer | [§6.1 Access control & sessions](#access) | Guacamole supports per-user disabled/valid-until attributes, but nothing in this build automatically disables an account after 45 days of inactivity — drive it from the IdP or an operational review. |
| `ism-1852` | Unprivileged access to systems, applications and data repositories is limited to only what is required for users and services to undertake their duties. | ✅ Implemented | [§6.1 Access control & sessions](#access) | Guacamole is deny-by-default: a user sees only connections and groups they hold a READ permission on, granted explicitly through `guac_users` / `guac_user_groups`. |
| `ism-principle-p11` | Personnel are granted the minimum access to systems, applications and data repositories required for their duties. | 🟡 Partial | [§6.1 Access control & sessions](#access) | Least privilege is applied throughout: per-connection permissions, DML-only DB account, nologin service accounts, sudo-only host administration. Deciding each person's minimum set is an IDAM activity. |

#### Privileged access management

| ISM control | Control statement (abridged from the dataset) | Status | Design reference | Coverage in this build |
|---|---|---|---|---|
| `ism-1507` | Requests for privileged access to systems and applications are validated when first requested. | 📋 Customer | [§6.3 Privileged access](#privileged) | Granting ADMINISTER or CREATE_* in `guac_user_groups` is an explicit, peer-reviewed change in version control — the validation of the request itself is an IDAM process. |
| `ism-1508` | Privileged access to systems and applications is limited to only what is required for users and services to undertake their duties. | 🟡 Partial | [§6.3 Privileged access](#privileged) | System permissions are granted individually (no implicit admin), service accounts hold none, and the DB account cannot alter schema. Reviewing that each admin still needs their grant is operational. |
| `ism-1509` | Privileged access events are logged. | ✅ Implemented | [§9 Logging & auditing](#logging) | The auditd ruleset logs privilege escalation directly: `-a always,exit -F arch=b64 -C euid!=uid -F auid!=unset -S execve -k privileged` plus `-w /usr/bin/sudo -p x -k priv-cmd`. |
| `ism-1649` | Just-in-time administration is used for administering systems and applications. | ❌ Not addressed | [§6.3 Privileged access](#privileged) | Access is standing, not just-in-time: a user with a READ permission can open that connection at any time. Time-bound elevation needs a PAM platform in front, or scripted grant/revoke against the Guacamole API. |
| `ism-1650` | Privileged account and group management events are logged. | ✅ Implemented | [§9 Logging & auditing](#logging) | auditd watches /etc/passwd, /etc/group, /etc/shadow and /etc/gshadow (`-k identity`) and /etc/sudoers plus /etc/sudoers.d/ (`-k scope`), capturing account and privileged-group changes. |
| `ism-1653` | Privileged service accounts are prevented from accessing the internet, email and web services. | 🟡 Partial | [§6.3 Privileged access](#privileged) | guacd and tomcat are unprivileged, shell-less accounts with no outbound requirement beyond the brokered target sessions; host egress is limited by firewall policy and, in an air-gapped build, to an internal mirror. |
| `ism-1688` | Unprivileged accounts cannot logon to privileged operating environments. | 🟡 Partial | [§6.3 Privileged access](#privileged) | An unprivileged Guacamole user cannot reach an administrative connection they hold no permission on, and cannot log on to the host itself — only nominated administrators have SSH access. |
| `ism-1689` | Privileged accounts (excluding local administrator accounts) cannot logon to unprivileged operating environments. | 🟡 Partial | [§6.3 Privileged access](#privileged) | The guacd and tomcat accounts cannot log on at all (/sbin/nologin, password-locked, cron-denied); host administration is a named sudo account over hardened SSH. |

#### Event logging, central storage, monitoring and time

| ISM control | Control statement (abridged from the dataset) | Status | Design reference | Coverage in this build |
|---|---|---|---|---|
| `ism-0109` | Event logs are analysed in a timely manner to detect cyber security events. | 📋 Customer | [§9.3 Monitoring & response](#monitoring) | The build produces the telemetry (auditd, nginx, Tomcat/Guacamole, guacd, MariaDB) and ships it; timely analysis is a SOC/SIEM function. |
| `ism-0580` | An event logging policy is developed, implemented and maintained. | 📋 Customer | [§9 Logging & auditing](#logging) | The build implements an event-logging *configuration* (auditd ruleset, rsyslog forwarding, application logs); the governing policy document is an organisational artefact. |
| `ism-0582` | The following events are logged for operating systems: application and operating system crashes and error messages; changes to security policies and system configurations; successful user logons and logoffs, failed user logons and account lockouts; failures, restarts and changes to important … | ✅ Implemented | [§9 Logging & auditing](#logging) | auditd plus journald cover the listed events: logons/logoffs and lockouts (/var/log/lastlog, /var/run/faillock), security policy and configuration changes (/etc/selinux, sshd_config, /etc/guacamole), service state and system start/stop. |
| `ism-0585` | For each event logged, the date and time of the event, the relevant user or process, the relevant filename, the event description, and the ICT equipment involved are recorded. | ✅ Implemented | [§9 Logging & auditing](#logging) | auditd records date/time, auid/uid, the object or filename, the syscall and key, and the host, for every rule in the deployed ruleset; nginx logs timestamp, client IP, request and status. |
| `ism-0859` | Event logs, excluding those for Domain Name System services and web proxies, are retained for at least seven years. | 📋 Customer | [§9 Logging & auditing](#logging) | Locally, logs rotate on distribution defaults — nowhere near seven years. Authoritative retention is the central facility's; forward early so the host is not the system of record. |
| `ism-0988` | An accurate time source is established and used consistently across systems to assist with identifying connections between events. | ✅ Implemented | [§9 Logging & auditing](#logging) | `guac_hardening_time_sync` installs and enables chrony against `guac_hardening_ntp_servers` (or the distro pool), and the database runs in UTC (`guac_db_timezone`), so timestamps correlate across sources. |
| `ism-1228` | Cyber security events are analysed in a timely manner to identify cyber security incidents. | 📋 Customer | [§9.3 Monitoring & response](#monitoring) | Candidate use cases from this host: failed admin logons, auditd privilege events, nginx 4xx/5xx spikes, unexpected guacd connection patterns. Triage to incident is the SOC's. |
| `ism-1405` | A centralised event logging facility is implemented and event logs are sent to the facility as soon as possible after they occur. | 🟡 Partial | [§9 Logging & auditing](#logging) | With `guac_syslog_target` set, rsyslog forwards continuously with a 50,000-entry linked-list queue and infinite resume retries, and audisp pushes auditd events into the same stream. The facility itself is the SIEM. |
| `ism-1566` | Use of unprivileged access is logged. | ✅ Implemented | [§9 Logging & auditing](#logging) | Guacamole records a history entry per login and per connection (user, connection, start/end), nginx logs every request with the real client IP, and auditd logs OS logons. |
| `ism-1651` | Privileged access event logs are stored centrally. | 🟡 Partial | [§9 Logging & auditing](#logging) | Privileged-access events are captured by auditd and reach the SIEM through the audisp→rsyslog→collector path; that path is only active when `guac_syslog_target` is configured. |
| `ism-1652` | Privileged account and group management event logs are stored centrally. | 🟡 Partial | [§9 Logging & auditing](#logging) | The identity/scope auditd rules (account and group management) travel over the same forwarding path, so they land centrally whenever forwarding is enabled. |
| `ism-1683` | Successful and unsuccessful multi-factor authentication events are logged. | 🟡 Partial | [§9 Logging & auditing](#logging) | The TOTP/Duo extensions log successful and failed second-factor attempts through Tomcat's logger alongside the primary authentication result; retention and alerting are the SIEM's. |
| `ism-1714` | Unprivileged access event logs are stored centrally. | 🟡 Partial | [§9 Logging & auditing](#logging) | Unprivileged access events — Guacamole logins and connection history, nginx access logs, OS logons — forward centrally under the same `guac_syslog_target` condition. |
| `ism-1747` | Operating system event logs are stored centrally. | 🟡 Partial | [§9 Logging & auditing](#logging) | OS and auditd logs reach the collector once `guac_syslog_target` is set (rsyslog omfwd/omrelp + audisp syslog plugin). Until then, logs are local only. |
| `ism-1757` | Web application event logs are stored centrally. | 🟡 Partial | [§9 Logging & auditing](#logging) | nginx and Tomcat/Guacamole logs are forwarded by the same rsyslog configuration once `guac_syslog_target` is set. |
| `ism-1815` | Event logs stored within a centralised event logging facility are protected from unauthorised modification and deletion. | 🟡 Partial | [§9 Logging & auditing](#logging) | In transit, `guac_syslog_tls` wraps forwarding in TLS with collector CA validation and optional mutual-TLS client certificates, and `guac_syslog_relp` makes delivery reliable. Protection at rest is the SIEM's control. |

#### Patch and vulnerability management

| ISM control | Control statement (abridged from the dataset) | Status | Design reference | Coverage in this build |
|---|---|---|---|---|
| `ism-0298` | A centralised and managed approach that maintains the integrity of patches or updates, and confirms that they have been applied successfully, is used to patch or update applications, operating systems, drivers and firmware. | 🟡 Partial | [§8 Patch & vulnerability management](#patching) | Ansible gives the centralised managed approach and every run ends by verifying the web app answers 200 and guacadmin can authenticate. Caveat: the EPEL and RPM Fusion release RPMs are installed with `disable_gpg_check: true`. |
| `ism-1143` | Patch management processes, and supporting patch management procedures, are developed, implemented and maintained. | 📋 Customer | [§8 Patch & vulnerability management](#patching) | The playbook is the patch *mechanism* — one idempotent re-run patches the OS and rolls Guacamole/Tomcat forward. The documented process, cadence and approvals are organisational. |
| `ism-1493` | Software registers for workstations, servers, network devices and other ICT equipment are developed, implemented, maintained and verified on a regular basis. | 🟡 Partial | [§11 Deployment & change management](#deploy) | group_vars/all.yml pins every component version, and the host records what is actually installed in `/usr/local/.guacd_build_id`, `/etc/guacamole/.guac_schema_version` and each backup MANIFEST. |
| `ism-1643` | Software registers contain versions and patch histories of applications, drivers, operating systems and firmware. | 🟡 Partial | [§11 Deployment & change management](#deploy) | Those same markers plus git history give the version and change history for the Guacamole stack; OS package patch history comes from the dnf/apt database, not from this repo. |
| `ism-1690` | Patches, updates or vendor mitigations for security vulnerabilities in internet-facing services are applied within two weeks of release, or within 48 hours if an exploit exists. | 🟡 Partial | [§8 Patch & vulnerability management](#patching) | For the internet-facing service itself (nginx, Tomcat, Guacamole) a version bump plus one re-run is the patch action; meeting the two-week / 48-hour windows is an operational SLA. |
| `ism-1694` | Patches, updates or vendor mitigations for security vulnerabilities in operating systems of internet-facing services are applied within two weeks of release, or within 48 hours if an exploit exists. | 🟡 Partial | [§8 Patch & vulnerability management](#patching) | `guac_auto_patch: true` installs dnf-automatic with `upgrade_type = security` and `apply_updates = yes` (unattended-upgrades on Debian) and enables the timer; it is off by default for change-control reasons. |
| `ism-1695` | Patches, updates or vendor mitigations for security vulnerabilities in operating systems of workstations, servers and network devices are applied within two weeks of release. | 🟡 Partial | [§8 Patch & vulnerability management](#patching) | Same mechanism as ism-1694 for the general server OS; every `site.yml` run also refreshes package metadata so a manual patch run is a single command. |
| `ism-1698` | A vulnerability scanner is used at least daily to identify missing patches or updates for security vulnerabilities in internet-facing services. | 📋 Customer | [§8 Patch & vulnerability management](#patching) | No vulnerability scanner is installed or scheduled by this build. Point your existing credentialed scanner at the host and feed findings into the patch cycle. |

#### Data backup and restoration

| ISM control | Control statement (abridged from the dataset) | Status | Design reference | Coverage in this build |
|---|---|---|---|---|
| `ism-1511` | Backups of important data, software and configuration settings are performed and retained with a frequency and retention timeframe in accordance with business continuity requirements. | ✅ Implemented | [§10 Backup & recovery](#backup) | `guac-backup` runs on a systemd timer (`guac_backup_schedule_oncalendar`, default 00:30 daily) and bundles the database dump, /etc/guacamole and the nginx TLS/site config; `guac_backup_retention_days` prunes. |
| `ism-1515` | Restoration of important data, software and configuration settings from backups to a common point of time is tested as part of disaster recovery exercises. | ✅ Implemented | [§10 Backup & recovery](#backup) | `test/dr.sh` is an automated DR exercise: build host A, back up, restore onto a fresh host B, then verify guacadmin login and that connection data survived. |
| `ism-1547` | Data backup processes, and supporting data backup procedures, are developed, implemented and maintained. | 🟡 Partial | [§10 Backup & recovery](#backup) | The backup process is codified in `guac-backup` and documented in docs/OPERATIONS.md; the organisational data backup policy that governs it sits outside this repository. |
| `ism-1548` | Data restoration processes, and supporting data restoration procedures, are developed, implemented and maintained. | 🟡 Partial | [§10 Backup & recovery](#backup) | `guac-restore <bundle>` performs the full restore — stop services, overlay config, reload the database, restore TLS, restart, wait for HTTP 200 — and docs/OPERATIONS.md is the runbook. |
| `ism-1705` | Privileged accounts (excluding backup administrator accounts) cannot access backups belonging to other accounts. | 🟡 Partial | [§10 Backup & recovery](#backup) | On-host, root can read every bundle — separation between a backup administrator and other privileged accounts only becomes real once bundles are copied to a backup system with its own account model. |
| `ism-1706` | Privileged accounts (excluding backup administrator accounts) cannot access their own backups. | 🟡 Partial | [§10 Backup & recovery](#backup) | Same limitation: a local root-held backup is readable by that account. Shipping bundles to a system where the broker holds write-only credentials is the fix. |
| `ism-1707` | Privileged accounts (excluding backup administrator accounts) are prevented from modifying and deleting backups. | 🟡 Partial | [§10 Backup & recovery](#backup) | `guac-backup` only deletes bundles older than the retention window, but nothing prevents root deleting one early. Object-lock or write-once storage is required to satisfy this properly. |
| `ism-1708` | Privileged accounts (including backup administrator accounts) are prevented from modifying and deleting backups during their retention period. | ❌ Not addressed | [§10 Backup & recovery](#backup) | No mechanism here can prevent the backup administrator modifying or deleting bundles inside the retention period; that requires immutable storage (S3 Object Lock, WORM appliance or offline media). |
| `ism-1810` | Backups of important data, software and configuration settings are synchronised to enable restoration to a common point in time. | ✅ Implemented | [§10 Backup & recovery](#backup) | One bundle is one point in time: a `--single-transaction` database dump plus the configuration and TLS material are captured together, so a restore never mixes eras. |
| `ism-1811` | Backups of important data, software and configuration settings are retained in a secure and resilient manner. | 🟡 Partial | [§10 Backup & recovery](#backup) | Bundles carry per-file SHA-256 plus a bundle-level `.sha256`, and `guac_backup_gpg_passphrase` encrypts them with AES-256. Resilience needs an off-host copy — store the passphrase separately or the bundles are unrecoverable. |
| `ism-1812` | Unprivileged accounts cannot access backups belonging to other accounts. | ✅ Implemented | [§10 Backup & recovery](#backup) | /var/backups/guacamole is 0700 root:root and the scripts run with `umask 077`, so no unprivileged account can read another account's backup. |
| `ism-1813` | Unprivileged accounts cannot access their own backups. | ✅ Implemented | [§10 Backup & recovery](#backup) | The same 0700 root-only directory means unprivileged accounts cannot read backups at all, including any of their own data within them. |
| `ism-1814` | Unprivileged accounts are prevented from modifying and deleting backups. | ✅ Implemented | [§10 Backup & recovery](#backup) | Write access to the bundle directory, the `guac-backup`/`guac-restore` scripts (0700 root) and the systemd timer all require root. |
| `ism-principle-p9` | Data, applications and configuration settings are backed up in a secure and proven manner on a regular basis. | ✅ Implemented | [§10 Backup & recovery](#backup) | Data (database), application configuration (/etc/guacamole, extensions, lib) and TLS material are backed up on a schedule, checksummed, optionally encrypted, and the restore is proven by test/dr.sh. |
| `ism-principle-r3` | Business continuity and disaster recovery plans are enacted when required. | 📋 Customer | [§10 Backup & recovery](#backup) | `guac-restore` plus the docs/OPERATIONS.md runbook are the enactment mechanism; the business continuity and disaster recovery plans themselves are organisational documents. |

#### Software supply chain and build integrity

| ISM control | Control statement (abridged from the dataset) | Status | Design reference | Coverage in this build |
|---|---|---|---|---|
| `ism-1422` | Unauthorised access to the authoritative source for software is prevented. | 🟡 Partial | [§11 Deployment & change management](#deploy) | Access to the repository and to the Ansible Vault secrets is what grants the ability to change every host; protecting both is a source-control and secrets-management responsibility. |
| `ism-1791` | The integrity of applications, ICT equipment and services are assessed as part of acceptance of products and services. | 🟡 Partial | [§11 Deployment & change management](#deploy) | Artefacts are fetched over HTTPS from the Apache CDN with an archive.apache.org fallback and Maven Central, but the playbook does NOT verify their GPG signatures or published checksums, and the EPEL/RPM Fusion release RPMs use `disable_gpg_check: true`. |
| `ism-1792` | The authenticity of applications, ICT equipment and services are assessed as part of acceptance of products and services. | 🟡 Partial | [§11 Deployment & change management](#deploy) | Authenticity currently rests on TLS to the official mirrors plus pinned version strings. Mirroring artefacts internally after verifying signatures once is the recommended air-gap pattern. |
| `ism-1816` | Unauthorised modification of the authoritative source for software is prevented. | 🟡 Partial | [§11 Deployment & change management](#deploy) | This repository is the authoritative source for the host's configuration: changes are commits, peer-reviewed and applied by the pipeline, and a drifted host is corrected by the next run. |

<!-- END ISM TABLE -->

### 12.1 Control families explicitly out of scope for this component

These families were reviewed against the dataset and deliberately excluded: a browser-based
RDP/SSH/VNC broker on a single Linux host has no bearing on them. They are listed so an assessor
can see the exclusion was a decision, not an omission, and so the responsible artefact is named.

| Family | Indicative controls | Why it is out of scope / where it lives |
|---|---|---|
| **Physical security, facilities, security zones** | ism-0161, ism-0164, ism-0810, ism-0813, ism-1053, ism-1074, ism-1296, ism-1530, ism-principle-p14 | Property of the data centre / server room hosting the VM. |
| **Cabling, patch panels, wall outlets, conduits, labelling** | ism-0181–0218, ism-1095–1133, ism-1639, ism-1718–1722, ism-1820–1822 | Facilities / cabling standard. Nothing in a VM build touches it. |
| **Emanation security (TEMPEST), RF/IR devices** | ism-0246–0250, ism-0225, ism-0829, ism-1013, ism-1543 | ACSC emanation-security assessment; facility-level. |
| **Media handling, sanitisation, destruction, disposal** | ism-0311–0378, ism-0831–0840, ism-1065–1067, ism-1222–1226, ism-1600, ism-1642, ism-1722–1735 | Media-management policy and the equipment-disposal process. The build writes no removable media. |
| **ICT equipment lifecycle, maintenance, registers** | ism-0293–0310, ism-0336, ism-1550–1551, ism-1598–1599, ism-1741–1742 | ICT asset management. |
| **Personnel security, clearances, training, travel** | ism-0252, ism-0409–0447, ism-0434–0443, ism-1554–1556, ism-1299–1300, ism-1565, ism-1583, ism-1625–1626, ism-principle-p10, ism-principle-p13 | HR and security governance. |
| **Email, email gateways, protective markings, DMARC/SPF/DKIM** | ism-0264–0272, ism-0565–0574, ism-0861, ism-1023–1027, ism-1151, ism-1183, ism-1234, ism-1502, ism-1540, ism-1589, ism-1799 | Email infrastructure. The jump-host sends no mail. |
| **Web content filtering and web proxies** | ism-0258–0263, ism-0958–0963, ism-1171, ism-1236–1237, ism-1782, ism-1777 | Gateway / proxy platform. Guacamole is not a web proxy for users. |
| **Cross Domain Solutions, data transfer, content filtering** | ism-0597–0677, ism-1284–1294, ism-1521–1524, ism-1586, ism-1778–1779 | CDS platform; this host brokers interactive sessions, not file exchange between domains. |
| **Gateways as evaluated products, NIDS/NIPS, diodes, DMZ** | ism-0628–0645, ism-1028–1030, ism-1157–1158, ism-1528, ism-1192 (device level) | Network / gateway design and product selection. |
| **Wireless networks, Bluetooth, mobile devices, MDM** | ism-0682–0705, ism-0863–0874, ism-1082–1085, ism-1195–1200, ism-1314–1338, ism-1400, ism-1482, ism-1533 | Mobility platform. |
| **Telephony, video conferencing, fax, MFDs** | ism-0229–0245, ism-0546–0558, ism-0588–0591, ism-1019, ism-1036, ism-1078, ism-1562, ism-1854–1856 | Unified-communications and print platforms. |
| **Application development (OWASP, SAST/DAST, SecDevOps)** | ism-0400–0402, ism-0971, ism-1238–1241, ism-1419–1420, ism-1780, ism-1796–1798, ism-1849–1851 | Apache Guacamole is consumed upstream, not developed here. |
| **Application control / execution allow-listing** | ism-0843, ism-0846, ism-0955, ism-1392, ism-1471, ism-1490, ism-1582, ism-1656–1663, ism-1746 | Not configured — no fapolicyd or SELinux `execmod` policy. If your profile requires it, implement separately and record the decision as POA&M item 5. |
| **Microsoft-specific hardening (Office macros, PowerShell, AD DS, LSASS, Defender)** | ism-1487–1491, ism-1542–1544, ism-1601, ism-1621–1624, ism-1654–1678, ism-1686, ism-1745 (Windows), ism-1827–1847, ism-1861 | Windows estate. They apply to the *targets*, not to the Linux broker. |
| **Office productivity suites, browsers, PDF software on endpoints** | ism-1235, ism-1412, ism-1467–1470, ism-1485–1486, ism-1585, ism-1691–1692, ism-1699, ism-1748, ism-1823–1825, ism-1859–1860 | Client endpoints, which by design hold no Guacamole client software beyond a browser. |
| **Break-glass account process** | ism-1610 (process half), ism-1611–1615, ism-1715, ism-1795 | IDAM / PAM process. §12's ism-1610 row covers only the technical emergency-access path. |
| **Just-in-time administration, PAW/SAW, privileged workstations** | ism-1175, ism-1380–1381, ism-1649 (process half), ism-1687, ism-1749 | PAM platform and administrator endpoint build. |
| **Cloud, service providers, contracts, supply-chain assurance** | ism-0072, ism-0141, ism-1073, ism-1395, ism-1431–1439, ism-1451–1452, ism-1529, ism-1567–1580, ism-1631–1638, ism-1736–1738, ism-1785–1794, ism-1804 | Procurement and vendor management. |
| **Incident response, forensics, intrusion remediation** | ism-0043, ism-0123–0140, ism-0576, ism-0917, ism-1125, ism-1213, ism-1609, ism-1731–1732, ism-1784, ism-1803, ism-1819, ism-principle-r1/r2 | SOC and incident-management process. §12 covers producing the telemetry only. |
| **Organisational governance (CISO, strategy, budget, awareness)** | ism-0039, ism-0714–0735, ism-1478, ism-1617–1618, ism-principle-g1–g5 | Executive governance. |
| **Data classification, marking and registers** | ism-0293, ism-0323–0332, ism-0393, ism-1187, ism-1243, ism-1535 | Information-management process. Classify the Guacamole database per the data it brokers access to. |
| **High assurance cryptography (SECRET / TOP SECRET)** | ism-0142, ism-0460, ism-0467, ism-0499, ism-0501, ism-1802 | ASD-approved HACE. **FIPS mode does not satisfy these** — see the note in §7.4. The control this build bears on is ism-0465. |
| **IPsec / VPN, RADIUS, SNMP, DHCPv6, routing** | ism-0494–0498, ism-0998–1000, ism-1233, ism-1311–1312, ism-1428–1430, ism-1454, ism-1771–1772, ism-1783 | Network infrastructure; the broker uses none of these protocols. |
| **Hypervisor / software-based isolation** | ism-1460–1461, ism-1604–1607, ism-1848 | The virtualisation platform hosting this VM, not the guest. |
| **Vulnerability scanning cadence and asset discovery** | ism-1699–1703, ism-1752, ism-1807–1808, ism-1163 | External scanner and its schedule. §12's ism-1698 row records that no scanner is installed here. |

### 12.2 Residual actions (POA&M seed)

<a id="poam"></a>

Every ❌ and the material 🟡 rows in §12 roll up into these actions. Owners and dates are for the
system owner to complete.

| # | Action | Driving controls | Owner | Target |
|---|---|---|---|---|
| 1 | Run OpenSCAP / CIS-CAT against the built host; remediate or formally accept each finding (see `roles/cis`) | ism-1409, ism-1037 | `[SysAdmin]` | `[date]` |
| 2 | Set `guac_syslog_target` (with `guac_syslog_tls`) and confirm events arrive in `[SIEM]`; agree retention | ism-1405, ism-1747, ism-1651, ism-1714, ism-0859 | `[SecOps]` | `[date]` |
| 3 | Enable MFA and decide the **phishing-resistant** path — X.509 client certificate, or OIDC/SAML to a WebAuthn IdP | ism-0974, ism-1173, ism-1504, ism-1682 | `[IDAM]` | `[date]` |
| 4 | Implement account lockout: `fail2ban` against the Guacamole auth log, plus PAM `faillock` at the OS | ism-1403 | `[SysAdmin]` | `[date]` |
| 5 | Decide the application-control approach (fapolicyd / SELinux) or formally accept the risk | ism-1592, §12.1 | `[ITSA]` | `[date]` |
| 6 | Configure **off-host and immutable** backup storage (object lock / WORM / offline) | ism-1707, ism-1708, ism-1811, ism-1705 | `[BackupAdmin]` | `[date]` |
| 7 | Verify artefact integrity: mirror Apache/Maven artefacts internally after checking signatures; remove `disable_gpg_check` reliance | ism-1791, ism-1792, ism-0298 | `[Build team]` | `[date]` |
| 8 | Confirm partition / mount-option layout, Secure Boot state and full disk encryption at OS build | ism-1745, ism-0459, ism-1409 | `[Build team]` | `[date]` |
| 9 | Supply and deploy approved logon banner text to `/etc/issue.net` | ism-0408 | `[ITSA]` | `[date]` |
| 10 | Deploy the organisation's server antivirus/EDR agent; decide on HIPS | ism-1417, ism-1034 | `[SecOps]` | `[date]` |
| 11 | Decide the target-credential model: brokered storage (accepted) vs. pass-through / per-user prompting | ism-0418, ism-1402 | `[ITSA]` | `[date]` |
| 12 | Decide DB-level event logging (enable `server_audit`) and, for a remote DB, JDBC TLS | ism-1537, ism-1277 | `[DBA]` | `[date]` |
| 13 | If NIST-only curves are required, set `ssl_ecdh_curve` or enable FIPS; raise the internal guacd cert from RSA-2048 | ism-1446, ism-1761, ism-1765 | `[SysAdmin]` | `[date]` |
| 14 | Where a password policy is required, state where it is enforced (IdP / directory) and its parameters | ism-0421, ism-1595 | `[IDAM]` | `[date]` |
| 15 | If FIPS is in scope: enable, reboot, verify with `fips-mode-setup --check` and confirm the JVM provider | ism-0465 | `[SysAdmin]` | `[date]` |
| 16 | Remove the guacd build toolchain and source tree post-build, or record the acceptance | ism-1245 | `[SysAdmin]` | `[date]` |
| 17 | Scope target-side encryption: avoid VNC/telnet connections, or tunnel them | ism-0469, ism-1781 | `[Design authority]` | `[date]` |
| 18 | Apply outbound egress filtering upstream (the host firewall restricts inbound only) | ism-1416, ism-1182, ism-1388 | `[Network]` | `[date]` |
| 19 | Decide the just-in-time administration model — a PAM platform in front of the broker, or scripted time-bound grant/revoke against the Guacamole API — or formally accept standing access | ism-1649 | `[IDAM]` | `[date]` |

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
