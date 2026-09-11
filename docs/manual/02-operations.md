# 2. Day-to-Day Operations

## 2.1 The four services

| systemd unit | What it is | Runs as |
|---|---|---|
| `mariadb` | Database (only present if `guac_install_mariadb: true`; otherwise the database lives on a separate host and isn't managed here) | `mysql` |
| `guacd` | Guacamole proxy daemon | `guacd` (dedicated system account) |
| `tomcat` | Tomcat + `guacamole.war` | dedicated Tomcat system account |
| `nginx` | Reverse proxy + TLS | `nginx` (only present if `guac_install_nginx: true`, the default) |

### Starting, stopping, restarting

Standard `systemctl` verbs work on all four:

```bash
sudo systemctl status  mariadb guacd tomcat nginx
sudo systemctl start   guacd
sudo systemctl stop    tomcat
sudo systemctl restart nginx
sudo systemctl reload  nginx        # config-only change, no dropped connections
```

**Recommended stop/start order** when you need to bounce everything (e.g. after manual
maintenance): stop `nginx` → `tomcat` → `guacd` → `mariadb`; start in the reverse order
(`mariadb` → `guacd` → `tomcat` → `nginx`). Tomcat's unit already declares
`After=guacd.service` / `Wants=guacd.service`, so `systemctl restart tomcat` alone will not
restart `guacd` — restart it explicitly if you changed `guacd.conf`.

All four units are `enabled` (start on boot) by the playbook; `Restart=on-failure` is set on
`guacd` and `tomcat` so a crashed process is automatically relaunched.

### Health checks

```bash
# Are the services actually up?
systemctl is-active mariadb guacd tomcat nginx

# Is guacd actually listening?
(exec 3<>/dev/tcp/127.0.0.1/4822) 2>/dev/null && echo "guacd OK" || echo "guacd DOWN"

# Is Tomcat serving the app directly (bypasses nginx)?
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/guacamole/

# Is the HTTPS proxy serving it (self-signed cert, so -k)?
curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1/

# End-to-end: can guacadmin actually get a session token?
curl -sk -d 'username=guacadmin&password=<password>' https://127.0.0.1/api/tokens
```

A healthy host returns `200` from both curl checks and a JSON body containing `"authToken"` from
the last one. `test/check.sh` in the repository runs exactly these checks (plus the HTTP→HTTPS
redirect check) and is the reference implementation if you want to script your own monitoring.

### Logs

| What | Where | How to view it |
|---|---|---|
| Tomcat / Guacamole webapp | `/opt/tomcat/logs/catalina.out` (stdout/stderr of the `tomcat` unit) | `sudo tail -f /opt/tomcat/logs/catalina.out` or `journalctl -u tomcat -f` |
| Tomcat access log | `/opt/tomcat/logs/localhost_access_log.<date>.txt` (if enabled) | `tail -f` |
| guacd | systemd journal (guacd logs to stderr, captured by journald) | `journalctl -u guacd -f` |
| guacd (foreground debug) | n/a — run manually | `sudo systemctl stop guacd && sudo /usr/local/sbin/guacd -L debug -f` (foreground, verbose; `Ctrl-C` to stop, then `systemctl start guacd` to resume the service) |
| nginx access/error | `/var/log/nginx/access.log`, `/var/log/nginx/error.log` | `sudo tail -f /var/log/nginx/error.log` |
| MariaDB | systemd journal / distro-default MariaDB log | `journalctl -u mariadb -f` |
| auditd (security-relevant events) | `/var/log/audit/audit.log` | `sudo ausearch -k <key>` / `sudo aureport` |
| Forwarded logs (if `guac_syslog_target` set) | your central collector | see Chapter 9 |

`journalctl -u <unit> -f` works for any of the four services and is usually the fastest way to
watch a live problem unfold.

### Configuration file locations

| File | Purpose |
|---|---|
| `/etc/guacamole/guacamole.properties` | Main Guacamole webapp config — DB connection, `guacd-hostname`/`guacd-port`, which extensions are wired up, and every enabled extension's settings (LDAP, SSO, Duo, session timeout, etc). Templated by Ansible from `group_vars`/`host_vars` — hand-edits are overwritten on the next playbook run. |
| `/etc/guacamole/extensions/` | Installed extension jars (JDBC auth, LDAP, TOTP, Duo, SSO sub-modules, etc). Filenames are version-qualified, e.g. `guacamole-auth-jdbc-mysql-1.6.0.jar`. |
| `/etc/guacamole/lib/` | Supporting jars the extensions need at runtime (e.g. the MySQL Connector/J driver). |
| `/etc/guacamole/guacamole-<version>.war` (symlinked as `/opt/tomcat/webapps/guacamole.war`) | The Guacamole web application itself. See Chapter 7 for why it's version-qualified. |
| `/etc/guacamole/.guac_schema_version` | Marker recording which JDBC schema version has been applied — drives automatic upgrades (Chapter 7). Don't hand-edit. |
| `/etc/guacamole/guacd.conf` | guacd's own settings — bind host/port, TLS, logging. guacd reads this automatically from `GUACAMOLE_HOME` at startup. |
| `/etc/nginx/conf.d/guacamole.conf` | The nginx reverse-proxy vhost (proxy_pass to Tomcat, WebSocket upgrade headers, TLS settings, security headers). A second file exists for the X.509 client-cert vhost when that's enabled — see Chapter 5/6. |
| `/etc/nginx/ssl/cert/`, `/etc/nginx/ssl/private/` | TLS certificate and private key (self-signed or Let's Encrypt) — see Chapter 6. |

None of these need to be edited by hand in normal operation — change the corresponding Ansible
variable (Chapter 13, `docs/CONFIGURE.md`) and re-run `ansible-playbook site.yml`. Direct edits
to templated files are overwritten on the next run; that's a feature, not a footgun — it means
the playbook is always the source of truth and drift gets corrected automatically.

## 2.2 Useful one-liners

```bash
# All four services at a glance
systemctl status mariadb guacd tomcat nginx --no-pager

# Follow Tomcat's own log
journalctl -u tomcat -f

# nginx config sanity check before reloading
sudo nginx -t

# What extensions are actually installed right now?
ls -1 /etc/guacamole/extensions/

# What Guacamole/schema version is this host on?
cat /etc/guacamole/.guac_schema_version

# Force a re-converge without changing anything (confirms idempotence / fixes drift)
ansible-playbook site.yml
```

See Chapter 12 for what to do when one of the health checks above fails.
