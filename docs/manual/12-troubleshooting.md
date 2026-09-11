# 12. Troubleshooting

Symptom → likely cause → fix. Every entry below is either a real failure mode encountered during
this project's development (called out as such) or a documented behaviour of a component this
stack depends on.

## 12.1 Login fails: "Extension ... is not compatible with this version of Guacamole"

**Symptom:** every login attempt (database, LDAP, or SSO) fails after an upgrade, with this
message in `catalina.out` / on screen.

**Cause:** the installed `guacamole.war` and the installed JDBC (or other) extension jars are at
*different* Guacamole versions — the webapp refuses to load an extension built for a different
release. Historically this happened when the war was downloaded to an **unversioned** path
(`guacamole.war`): `ansible.builtin.get_url` compares local mtime against the remote
`Last-Modified` header, and on a version bump could conclude the existing file was already
current and skip the download — leaving a stale war paired with freshly-upgraded extensions.

**Fix (already applied in this codebase):** the war is stored at a **version-qualified** path
(`/etc/guacamole/guacamole-<version>.war`, symlinked into Tomcat's `webapps/`), and stale-version
wars and extension jars are actively pruned on every run (see Chapter 7.2). If you ever see this
symptom on a current checkout, it means something bypassed the normal upgrade path (a manual file
copy, a partially-failed run) — resolve it by checking:

```bash
ls -la /etc/guacamole/*.war /opt/tomcat/webapps/guacamole.war
ls /etc/guacamole/extensions/
cat /etc/guacamole/.guac_schema_version
```

All of these should agree on one version. If they don't, re-run `ansible-playbook site.yml` at
the intended `guac_version` — the pruning logic will correct the mismatch.

## 12.2 guacd won't start, or the build fails with FreeRDP deprecation errors

**Symptom:** the `guacd` build step fails during `./configure` or `make`, often mentioning
`-Wdeprecated-declarations` or a `struct rdp_freerdp has no member named ...` error, on
Debian 13 / Ubuntu 24.04+ (FreeRDP 3.x).

**Cause:** `guacamole-server`'s `./configure` runs its feature-detection probes with `-Werror`,
so FreeRDP 3.x's normal deprecation warnings for APIs guacamole-server still uses get promoted to
hard errors and the probe fails, misreporting the feature as unavailable (or failing the build
outright).

**Fix:** `guac_server_configure_cppflags` defaults to `-Wno-error=deprecated-declarations`,
applied as `CPPFLAGS` to `./configure` specifically because `CPPFLAGS` lands *after* `-Werror` on
the command line and can selectively downgrade that one warning class back to non-fatal. If
you've overridden `guac_server_configure_cppflags` or `guac_server_configure_extra` and hit this,
restore the default (or append `-Wno-error=deprecated-declarations` to whatever you've set).

**Also check**, if guacd builds but the service won't start:

```bash
sudo systemctl status guacd
journalctl -u guacd -n 50 --no-pager
sudo /usr/local/sbin/guacd -L debug -f     # foreground, verbose (stop the service first)
```

## 12.3 RDP connection fails with a certificate error

**Symptom:** an RDP connection fails immediately with a certificate-related error in the session
log / guacd log.

**Cause:** the RDP target presents a self-signed or otherwise untrusted certificate and the
connection isn't configured to accept it.

**Fix:** set `ignore-cert: "true"` in that connection's `parameters` (Chapter 4) — this is the
normal, expected setting for internal Windows hosts using their default self-signed RDP
certificate. If the target *should* have a trusted certificate and doesn't, that's a target-side
configuration gap worth fixing rather than papering over with `ignore-cert`.

## 12.4 nginx returns 502 Bad Gateway

**Symptom:** `https://<proxy_site>/` returns `502` instead of the login page.

**Cause:** nginx is up but Tomcat (its upstream, `guac_proxy_upstream` — `127.0.0.1:8080`) isn't
answering — Tomcat hasn't finished starting, crashed, or failed to deploy the webapp.

**Fix:**

```bash
sudo systemctl status tomcat
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/guacamole/   # bypass nginx entirely
journalctl -u tomcat -n 100 --no-pager
tail -100 /opt/tomcat/logs/catalina.out
```

If Tomcat is active but the direct curl also fails, see §12.7 (Tomcat not deploying the war).

## 12.5 MariaDB timezone table errors

**Symptom:** a query or Guacamole session involving time-zone conversion fails, or the timezone
configuration step in the `database` role errors out.

**Cause:** MariaDB's `mysql.time_zone_name` table is empty until timezone data is explicitly
loaded from the OS's zoneinfo database — a common gap on minimal container base images that lack
`/usr/share/zoneinfo`, or where the database was bootstrapped by something other than this
playbook.

**Fix:** the `database` role already checks `SELECT COUNT(*) FROM mysql.time_zone_name` and, if
empty, runs `mariadb-tzinfo-to-sql /usr/share/zoneinfo` (falling back to the older
`mysql_tzinfo_to_sql` binary name) piped into the `mysql` database, then restarts MariaDB and sets
`default_time_zone` (`guac_db_timezone`, default `UTC`). If this still fails on your OS image:

```bash
# confirm zoneinfo exists at all
ls /usr/share/zoneinfo | head
# on minimal images missing it: install the OS's timezone-data package, then re-run
```

Set `guac_db_timezone: ""` to skip timezone configuration entirely if your environment doesn't
need it (e.g. a remote DB a DBA already manages).

## 12.6 Schema-version marker mismatch

**Symptom:** `/etc/guacamole/.guac_schema_version` doesn't match what you expect, or an upgrade
run didn't apply any schema SQL when you expected it to.

**Cause:** the upgrade logic (Chapter 7.4) only applies `upgrade-pre-*.sql` scripts when the
marker file exists **and** records a version older than `guac_version`. If the marker is missing
entirely — most often a database that pre-dates this tooling, or one restored from an external
source without the accompanying marker file — the playbook does not guess at what schema state
the database is actually in; it runs no upgrade SQL and simply stamps the marker at the current
`guac_version`.

**Fix:** if you know the database's actual schema version, write it to the marker file yourself
*before* running an upgrade, so the version range comparison is correct:

```bash
echo "1.5.5" | sudo tee /etc/guacamole/.guac_schema_version
```

Then proceed with the normal upgrade (Chapter 7). Never hand-edit the marker to a version *newer*
than the database's real schema — that would cause a future upgrade to skip SQL scripts the
database actually needs.

## 12.7 Tomcat is running but not serving `/guacamole/`

**Symptom:** `systemctl status tomcat` shows active, but `curl http://127.0.0.1:8080/guacamole/`
returns 404 or connection refused.

**Cause candidates, in likely order:**

1. The war hasn't finished exploding yet (large war, slow disk) — the playbook's own wait loop
   (`until: _guac_web.status == 200`, 40 retries × 5s) usually absorbs this; if you're checking
   manually right after a restart, just wait a few seconds and retry.
2. The webapp failed to deploy because an extension jar is broken or version-mismatched — check
   `catalina.out` for a stack trace naming the offending extension, and see §12.1.
3. `GUACAMOLE_HOME` isn't visible to the Tomcat process — check the `tomcat.service` unit's
   `Environment="GUACAMOLE_HOME=..."` line matches `guac_home`.
4. The exploded webapp/work cache is stale from a prior version and wasn't cleared — this is
   handled automatically on a version change (Chapter 7.1 step 2), but if you've manually copied
   files around, clear `/opt/tomcat/webapps/guacamole/` and
   `/opt/tomcat/work/Catalina/localhost/guacamole/` and restart Tomcat.

## 12.8 `nginx -t` fails after a manual edit

**Symptom:** `sudo nginx -t` reports a syntax error, usually after hand-editing
`/etc/nginx/conf.d/guacamole.conf` or `/etc/nginx/nginx.conf` outside of Ansible.

**Cause:** the nginx role's `nginx.conf` deployment uses `validate: "nginx -t -c %s"` — a broken
config template fails the Ansible run itself, so this is almost always caused by a manual,
out-of-band edit rather than a playbook bug.

**Fix:** manual edits to Ansible-templated nginx files are overwritten on the next run — the
cleanest fix is usually to revert the manual change and instead adjust the corresponding Ansible
variable / template, then `ansible-playbook site.yml --tags proxy`. To fix forward without a
re-run: correct the syntax error, `sudo nginx -t` again, then `sudo systemctl reload nginx`.

## 12.9 General diagnostic checklist

When nothing above matches, work outward from the request path (Chapter 1.3):

```bash
systemctl status mariadb guacd tomcat nginx --no-pager
journalctl -u tomcat -n 100 --no-pager
journalctl -u guacd -n 100 --no-pager
tail -50 /var/log/nginx/error.log
bash test/check.sh          # if the repo checkout is available on the host
```

`docs/OPERATIONS.md` and `README.md` cover the same ground for the person reading Ansible source;
if a failure mode you hit isn't listed here, it's worth adding once diagnosed, so the next person
doesn't have to re-derive it.
