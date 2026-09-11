# Scenarios — copy-paste configurations

Each block goes in `host_vars/<hostname>.yml` (or `group_vars/all.yml`). Combine as needed.
Put real secrets in an Ansible Vault file, not here.

---

## 1. Minimal lab install (all defaults)

`group_vars/all.yml`:

```yaml
guac_proxy_site: "guac.lab.local"
guac_db_password: "lab-db-pw-change-me"
guac_mysql_root_password: "lab-root-pw-change-me"
```

Run `ansible-playbook site.yml`, browse `https://guac.lab.local/`, log in `guacadmin/guacadmin`.

---

## 2. Production install with a real (Let's Encrypt) certificate

```yaml
guac_proxy_site: "guac.example.com"
guac_tls_mode: letsencrypt
guac_le_dns_name: "guac.example.com"     # public DNS A record -> this host
guac_le_email: "it-ops@example.com"
guac_db_password: "{{ vault_guac_db_pw }}"
guac_mysql_root_password: "{{ vault_guac_root_pw }}"
guac_hardening_ssh_password_auth: false  # key-only SSH
```

Port 80 must be reachable from the internet for the ACME challenge.

---

## 3. Separate / dedicated database server

Guacamole on host A, MariaDB/MySQL already running on `db01`:

```yaml
guac_install_mariadb: false
guac_mysql_host: "db01.example.com"
guac_mysql_port: 3306
guac_db_name: "guacamole_db"
guac_db_user: "guacamole_user"
guac_db_password: "{{ vault_guac_db_pw }}"

# Used ONCE to create the database, user and load the schema:
guac_mysql_admin_user: "root"
guac_mysql_root_password: "{{ vault_db01_admin_pw }}"
```

The admin account only needs rights to `CREATE DATABASE`, `CREATE USER`, `GRANT` on that DB, and
to load the schema. If your DBA has already created everything:

```yaml
guac_db_bootstrap: false
```

Open the DB port if the firewall is in the way: `guac_firewall_extra_ports: ["3306/tcp"]` on the
DB host is not managed here — do that on the DB server.

---

## 4. Enable TOTP (Google Authenticator) MFA

```yaml
guac_totp_enabled: true
```

That's it. On next login each user is prompted to enrol.

---

## 5. Enable Duo MFA

```yaml
guac_duo_enabled: true
guac_duo:
  api_hostname: "api-XXXXXXXX.duosecurity.com"
  integration_key: "{{ vault_duo_ikey }}"
  secret_key: "{{ vault_duo_skey }}"
  application_key: "{{ vault_duo_akey }}"   # any 40+ char random string, keep it stable
```

---

## 6. Active Directory / LDAP login

```yaml
guac_ldap_enabled: true
guac_ldap:
  hostname: "dc1.corp.example dc2.corp.example"
  port: 636
  encryption_method: ssl
  search_bind_dn: "svc-guacamole@corp.example"
  search_bind_password: "{{ vault_ldap_bind_pw }}"
  config_base_dn: "dc=corp,dc=example"
  user_base_dn: "OU=Staff,DC=corp,DC=example"
  username_attribute: sAMAccountName
  user_search_filter: "(&(objectClass=user)(!(objectCategory=computer)))"
  max_search_results: 500
```

LDAP users log in with their directory credentials; per-connection permissions are still managed
in Guacamole (or via `guac_users` below with matching usernames).

---

## 6a. OpenID Connect (Keycloak / Entra ID / Okta / Google)

```yaml
guac_openid_enabled: true
guac_openid:
  authorization_endpoint: "https://idp.example.com/realms/corp/protocol/openid-connect/auth"
  jwks_endpoint:          "https://idp.example.com/realms/corp/protocol/openid-connect/certs"
  issuer:                 "https://idp.example.com/realms/corp"
  client_id:              "guacamole"
  redirect_uri:           "https://guac.example.com/"
  username_claim_type:    "preferred_username"
  groups_claim_type:      "groups"
```

Register `https://guac.example.com/` as an allowed redirect URI at the IdP. Guacamole shows an
SSO button on the login page; the database still holds connections and permissions. Groups from
the `groups` claim line up with `guac_user_groups` for RBAC. Stack MFA by also setting
`guac_totp_enabled: true`.

## 6b. SAML 2.0 (ADFS / Entra ID / Shibboleth)

```yaml
guac_saml_enabled: true
guac_saml:
  idp_metadata_url: "https://idp.example.com/federationmetadata/2007-06/federationmetadata.xml"
  entity_id:        "https://guac.example.com/"
  callback_url:     "https://guac.example.com/"
  group_attribute:  "groups"
  strict: true
```

If your IdP has no metadata URL, drop `idp_metadata_url` and set `idp_url` instead (with
`entity_id`). The IdP must POST assertions to `https://guac.example.com/` (the `callback_url`).

## 6c. Smart card / X.509 client certificate

```yaml
guac_ssl_auth_enabled: true
guac_ssl_auth_domain: "cert.guac.example.com"        # + a *.cert.guac.example.com DNS record
guac_ssl_auth_client_ca: "{{ vault_client_issuing_ca_pem }}"
guac_ssl_auth:
  auth_uri:    "https://cert.guac.example.com/"
  primary_uri: "https://guac.example.com/"
  subject_username_attribute: "CN"
```

The nginx role adds a second TLS vhost for `cert.guac.example.com` (and `*.cert...`) that does
`ssl_verify_client optional` and forwards the verified certificate; it also scrubs the
`X-Client-*` headers on the normal vhost so a browser cannot forge an identity. In production
give that vhost a **wildcard** certificate. Users click *"Certificate / Smart Card"* on the
login page, the browser prompts for a cert, and the CN becomes the Guacamole username.

---

## 7. Define your backend servers (RDP / SSH / VNC)

```yaml
guac_connection_groups:
  - { name: "Production", parent: "ROOT", type: "ORGANIZATIONAL" }
  - { name: "Windows",    parent: "Production", type: "ORGANIZATIONAL" }
  - { name: "Linux",      parent: "Production", type: "ORGANIZATIONAL" }

guac_connections:
  - name: "dc01 (RDP)"
    parent: "Windows"
    protocol: rdp
    parameters:
      hostname: "10.0.1.10"
      port: "3389"
      security: "nla"
      ignore-cert: "true"
      domain: "CORP"
      enable-drive: "true"
      drive-name: "guac-transfer"
      drive-path: "/var/lib/guacamole/drive/${GUAC_USERNAME}"
      create-drive-path: "true"
    attributes:
      max-connections: "5"
      max-connections-per-user: "1"

  - name: "web01 (SSH)"
    parent: "Linux"
    protocol: ssh
    parameters:
      hostname: "10.0.2.20"
      port: "22"
      username: "deploy"
      # prefer key auth:
      private-key: "{{ vault_web01_ssh_key }}"

  - name: "kiosk (VNC)"
    parent: "Production"
    protocol: vnc
    parameters:
      hostname: "10.0.3.30"
      port: "5900"
      password: "{{ vault_kiosk_vnc_pw }}"
```

Re-run `ansible-playbook site.yml` (or `--tags connections`). Add/remove entries any time.

---

## 8. Create Guacamole users and grant access

```yaml
guac_users:
  - username: "alice"
    password: "{{ vault_alice_pw }}"
    attributes: { "guac-full-name": "Alice Smith", "guac-email-address": "alice@example.com" }
    connections: ["dc01 (RDP)", "web01 (SSH)"]
    groups: ["Linux"]

  - username: "bob"
    password: "{{ vault_bob_pw }}"
    system_permissions: ["CREATE_CONNECTION"]
    groups: ["Production"]
```

`connections` / `groups` grant **use** (READ) permission. `system_permissions` grant
account-wide rights. To make this playbook the single source of truth and delete anything not
listed: `guac_connections_prune: true` (careful).

---

## 9. Session recording

```yaml
guac_histrec_enabled: true
guac_histrec_path: "/var/lib/guacamole/recordings"
```

Then set `recording-path` (and optionally `recording-name`) in a connection's `parameters`.

---

## 10. Maximum hardening + FIPS

```yaml
guac_hardening_enabled: true
guac_hardening_level: l2
guac_hardening_ssh_password_auth: false
guac_guacd_tls_enabled: true
guac_fips_enabled: true        # RHEL: needs a reboot afterwards. Ubuntu: needs Ubuntu Pro.
```

Reboot the host after the run to activate FIPS, then re-run the playbook to finish verification.

---

## 11. Encrypted, off-box backups

```yaml
guac_backup_gpg_passphrase: "{{ vault_backup_passphrase }}"
guac_backup_schedule_oncalendar: "*-*-* 02:00:00"
guac_backup_retention_days: 60
```

Ship `/var/backups/guacamole/*.gpg` off the host with your normal file-transfer tooling. See
OPERATIONS.md for the restore procedure.

## 12. Load-balanced RDP pool

```yaml
guac_connection_groups:
  - { name: "Prod", parent: "ROOT", type: "ORGANIZATIONAL" }
  - name: "TS-farm"
    parent: "Prod"
    type: "BALANCING"          # Guacamole routes each session to the least-loaded member
    session_affinity: true     # pin a user to one member for the life of the session
    max_connections_per_user: "1"

guac_connections:
  - { name: "ts01", parent: "TS-farm", protocol: rdp, parameters: { hostname: "10.0.5.11", port: "3389", security: "nla", "ignore-cert": "true" } }
  - { name: "ts02", parent: "TS-farm", protocol: rdp, parameters: { hostname: "10.0.5.12", port: "3389", security: "nla", "ignore-cert": "true" } }
  - { name: "ts03", parent: "TS-farm", protocol: rdp, parameters: { hostname: "10.0.5.13", port: "3389", security: "nla", "ignore-cert": "true" } }
```

Grant users access to the **group** (`groups: ["TS-farm"]` in `guac_users`) — they connect to
the pool, not individual hosts.
