# Ansible Guacamole Installer — RHEL 9 / 10 edition

An Ansible-native reimplementation of
[itiligent/Easy-Guacamole-Installer](https://github.com/itiligent/Easy-Guacamole-Installer).
No numbered shell scripts — everything is an idempotent role. Target platform is the
**RHEL 9 / RHEL 10** family (RHEL, Oracle Linux, Rocky, Alma).

It builds a Guacamole jump-host:

- `guacamole-server` (guacd) **compiled from source** at a pinned version
- Guacamole web client on **Apache Tomcat** (installed from the official binary tarball)
- **MariaDB** JDBC auth backend + schema import + MySQL Connector/J
- **Nginx** reverse proxy with **self-signed TLS** (swap in Let's Encrypt for production)
- Optional extensions behind single toggles: TOTP, Duo, LDAP/AD, Quick Connect,
  History Recording Storage, and the dark-theme branding jar

## Layout

```
site.yml                 # full build
ansible.cfg
inventory/hosts.ini      # default: localhost (local connection)
group_vars/all.yml       # EVERY tunable (versions, DB creds, cert attrs, proxy DNS, toggles)
requirements.yml         # ansible.posix, community.mysql
roles/
  common/                # repos (EPEL/CRB), packages, firewalld, SELinux, guacd user, GUACAMOLE_HOME
  database/              # MariaDB, guac DB/user, schema import, connector/j, backup job
  guacd/                 # build + install guacamole-server, guacd.conf, systemd unit
  guacamole_client/      # Tomcat, guacamole.war, JDBC extension, guacamole.properties
  nginx_proxy/           # reverse proxy, RemoteIpValve, self-signed TLS, Let's Encrypt (opt)
  guac_extensions/       # TOTP / Duo / LDAP / quickconnect / histrec / branding
test/
  run.sh                 # spins OL9/OL10 systemd Podman containers, runs the playbook inside them
  check.sh               # functional verification (services, web app, proxy, guacadmin auth)
```

## Usage

### Against a real host

```bash
ansible-galaxy collection install -r requirements.yml
# edit inventory + group_vars/all.yml (at minimum: guac_db_password, guac_proxy_site)
ansible-playbook -i inventory/hosts.ini site.yml
```

Then browse to `https://<guac_proxy_site>/` and log in as `guacadmin` / `guacadmin`
(change it immediately).

### Key variables (`group_vars/all.yml`)

| Variable | Default | Purpose |
|---|---|---|
| `guac_version` | `1.6.0` | Guacamole version built/deployed |
| `guac_tomcat_version` | `9.0.109` | Apache Tomcat tarball version |
| `guac_proxy_site` | `<fqdn>` | DNS name for the proxy + TLS cert |
| `guac_db_password` / `guac_mysql_root_password` | placeholders | **override via vault** |
| `guac_tls_mode` | `self-signed` | `self-signed` \| `letsencrypt` \| `none` |
| `guac_le_dns_name` / `guac_le_email` | empty | required when `guac_tls_mode=letsencrypt` |
| `guac_totp_enabled` … `guac_branding_enabled` | mostly `false` | extension toggles |
| `guac_install_mariadb` | `true` | `false` → point at a remote DB via `guac_mysql_*` |
| `guac_install_nginx` | `true` | `false` → serve Tomcat directly on `:8080` |

### Production TLS (Let's Encrypt)

Set in `group_vars` (or `-e`):

```yaml
guac_tls_mode: letsencrypt
guac_le_dns_name: guac.example.com     # must resolve publicly, port 80 reachable
guac_le_email: admin@example.com
```

The `nginx_proxy` role installs `certbot` + the nginx plugin and runs
`certbot --nginx -d <dns> --redirect`. Until then, `self-signed` mode produces a working
HTTPS endpoint that mimics a signed certificate.

## Testing (Podman, no Ansible on the workstation)

`test/run.sh` never runs Ansible locally — it launches a **systemd-enabled Oracle Linux
container**, installs `ansible-core` + collections inside it, copies this repo in, and runs
`site.yml` there.

```bash
test/run.sh ol9      # Oracle Linux 9   (RHEL 9 family)
test/run.sh ol10     # Oracle Linux 10  (RHEL 10 family)
test/run.sh both
KEEP=1 test/run.sh ol9   # keep the container for inspection
```

Each target: first `site.yml` run → second run asserted `changed=0 failed=0` (idempotence)
→ `test/check.sh` verifies the four services are active, the web app returns the login page
over both `:8080` and the HTTPS proxy, and `guacadmin` can obtain an API auth token through
the proxy.

## Differences from the reference

| Reference (Debian/Ubuntu) | Here (RHEL 9/10) |
|---|---|
| `apt`, numbered `*.sh` scripts | `dnf`, idempotent Ansible roles |
| `ufw` | `firewalld` |
| (n/a) | SELinux booleans for the proxy |
| distro `tomcat9/10` package | Apache Tomcat binary tarball + systemd unit |
| MySQL root password prompt | MariaDB `unix_socket` root auth (no stored root password needed) |
| `sites-available` / `sites-enabled` | `/etc/nginx/conf.d/` + templated `nginx.conf` |
| interactive `1-setup.sh` menu | `group_vars/all.yml` |

Not in scope: Debian/Ubuntu, live Let's Encrypt in CI, LDAP login testing, enterprise
tiered MySQL cluster, upstream pushes.
