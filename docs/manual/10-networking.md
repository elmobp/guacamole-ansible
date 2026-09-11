# 10. Networking

The full port-by-port, flow-by-flow reference — the document to attach to a firewall change
request — is **`docs/FIREWALL.md`**. This chapter summarises it for operational purposes and
highlights the cases you'll hit most often; read the source document for the complete matrix and
the air-gapped/pre-staging guidance.

## 10.1 What's exposed, in, and out

**Inbound to the Guacamole host**, always:

| Port | Purpose |
|---|---|
| TCP 443 | HTTPS UI + WebSocket tunnel (TLS 1.3) — the only thing end users need |
| TCP 80 | 301 redirect to 443; also the ACME HTTP-01 challenge when `guac_tls_mode: letsencrypt` |
| TCP 22 | SSH, for the Ansible control node / admin access |
| TCP 8080 | Direct Tomcat — **only** if `guac_install_nginx: false` (not recommended) |

The playbook's own firewall management (`guac_manage_firewall: true`, `firewalld` on RHEL / `ufw`
on Debian family) opens 22/80/443 and **closes 8080** once the proxy is enabled. It manages only
this host's own firewall — upstream/edge firewalls between clients and this host still need those
same ports permitted separately.

**Outbound from the Guacamole host**, the flows that matter operationally:

| Destination | Port | When |
|---|---|---|
| RDP targets | TCP 3389 | any `rdp` connection |
| SSH/network targets | TCP 22 | any `ssh` connection |
| VNC targets | TCP 5900–5906 | any `vnc` connection |
| Kubernetes API | TCP 6443 | any `kubernetes` connection |
| Database server | TCP 3306 | only when `guac_install_mariadb: false` (local DB traffic never leaves loopback) |
| LDAP/AD DCs | TCP 636 (or 389 STARTTLS) | `guac_ldap_enabled: true` |
| Duo API | TCP 443 to `*.duosecurity.com` | `guac_duo_enabled: true` |
| Syslog/SIEM collector | TCP 6514 (TLS) / UDP 514 | recommended always — Chapter 9 |
| Backup target | your transfer port | recommended always — Chapter 8 |
| DNS, NTP | UDP/TCP 53, UDP 123 | always |

**Scope egress to backend targets narrowly** — the jump-host should reach the *specific* hosts or
subnets each declared connection needs, not the whole target network. This is the entire point of
a bastion: if this host is compromised, its blast radius to your estate should be limited to
exactly what's declared in `guac_connections`.

## 10.2 The separate-database-server case

When `guac_install_mariadb: false`, the only additional network requirement versus the default
(local DB) build is outbound TCP 3306 from the Guacamole host to `guac_mysql_host` — see
`docs/FIREWALL.md` O6. The database server's own firewall must permit inbound 3306 from the
Guacamole host's IP (or subnet); that's configured on the DB host, not by this playbook. See
Chapter 5 of `docs/CONFIGURE.md` and `docs/SCENARIOS.md` §3 for the corresponding variables
(`guac_mysql_host`, `guac_mysql_port`, `guac_mysql_admin_user`, `guac_db_bootstrap`).

## 10.3 SSO identity-provider egress

Each SSO method needs outbound HTTPS (443) reachability to your identity provider for the
protocol exchange itself (token/metadata endpoints) — this is normal web egress, not called out
as a separate firewall row in `docs/FIREWALL.md` because it's typically already open. If your
environment restricts general outbound HTTPS, explicitly permit:

| Method | Destination |
|---|---|
| OpenID Connect | the IdP's `authorization_endpoint` and `jwks_endpoint` hosts |
| SAML | the IdP host referenced by `idp_metadata_url` / `idp_url` |
| CAS | the CAS server host (`authorization_endpoint`) |
| X.509 client-certificate | none — this is a local TLS handshake against the CA bundle in `guac_ssl_auth_client_ca`; no outbound call to a PKI service is required at login time |

## 10.4 Build-time-only egress

During `ansible-playbook site.yml` (initial install, and any run that changes `guac_version` or
adds an extension), this host also needs outbound HTTPS to distro package mirrors,
`dlcdn.apache.org` / `archive.apache.org` (Guacamole source, war, JDBC, Tomcat), and
`repo1.maven.org` (MySQL Connector/J). These can be closed between changes on a tightly-controlled
network. For an air-gapped or IRAP-style build, `docs/FIREWALL.md` documents pre-staging these
artifacts on an internal mirror and repointing `guac_apache_dl_base`, `guac_tomcat_dl_base`,
`guac_mysql_connector_j_url`, and `guac_jdbc_archive_url` at it — after which the only runtime
egress required is the operational set in §10.1.

## 10.5 Loopback-only (informational — never crosses the network)

| Flow | Address |
|---|---|
| nginx → Tomcat | `127.0.0.1:8080` |
| Tomcat → guacd | `127.0.0.1:4822` (or TLS 1.3 if `guac_guacd_tls_enabled` and guacd runs elsewhere) |
| Tomcat/guac-backup → local MariaDB | Unix socket (`guac_mariadb_socket`) |

If you're raising a change request, copy the minimum production ruleset straight out of
`docs/FIREWALL.md` §5 — it's already written in a firewall-rule-like format ready to hand to a
network team.
