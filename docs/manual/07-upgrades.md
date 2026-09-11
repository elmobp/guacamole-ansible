# 7. Upgrades

Upgrading Guacamole is a one-line change:

```yaml
# group_vars/all.yml
guac_version: "1.6.1"     # was "1.6.0" — that's the only line that changes
```

```bash
ansible-playbook site.yml
```

**Before a production upgrade:** take a backup (`sudo /usr/local/sbin/guac-backup` — Chapter 8)
and read the upstream Guacamole release notes for the target version. Test the exact upgrade path
first with `test/upgrade.sh ol9 <old-version> <new-version>` (or against a staging host that
mirrors production) before touching a production host.

## 7.1 What happens automatically

1. **guacd is rebuilt.** Because `guac_version` changed, the `guacd` role's `creates:` guard on
   the compiled binary no longer matches, so `guacamole-server` is re-downloaded and recompiled
   from source at the new version, then reinstalled and the service restarted.
2. **`guacamole.war` is refreshed.** The war is fetched to a **version-qualified path** —
   `/etc/guacamole/guacamole-<version>.war` — and `/opt/tomcat/webapps/guacamole.war` is
   re-pointed to it as a symlink. Tomcat's exploded webapp directory and work cache
   (`webapps/guacamole/`, `work/Catalina/localhost/guacamole/`) are cleared so Tomcat re-explodes
   the new war rather than serving stale compiled JSPs.
3. **Every enabled extension jar is refreshed at the new version** the same way — JDBC MySQL auth,
   LDAP, TOTP, Duo, Quick Connect, History Recording Storage, and any enabled SSO sub-module
   (`guacamole-auth-sso-<method>-<version>.jar`).
4. **Stale-version artifacts are removed** — old wars, old JDBC/extension jars, and (see §7.4) the
   legacy unversioned `guacamole.war` layout, are all cleaned up so Tomcat is never left able to
   load a mismatched war/extension pair.
5. **Database schema upgrade scripts run.** `roles/database/tasks/schema_upgrade.yml` compares
   the version recorded in `/etc/guacamole/.guac_schema_version` against `guac_version`; if the
   recorded version is older, every `upgrade-pre-*.sql` script in the new
   `guacamole-auth-jdbc-<version>/mysql/schema/upgrade/` directory whose version falls in that
   range is applied, in order, via `community.mysql.mysql_db`. The marker file is then updated to
   the new version.
6. **Services restart** (guacd, Tomcat) and the playbook's own post-task **verifies `guacadmin`
   can still obtain an API token** before declaring success.

Tomcat itself can also be bumped independently:

```yaml
guac_tomcat_version: "9.0.122"
```

The old Tomcat tree is left on disk (nothing depends on removing it — it isn't in the webapps
path); the `/opt/tomcat` symlink is simply repointed at the newly unpacked version and the
service restarts.

## 7.2 Why the war is version-qualified

Earlier iterations of this playbook downloaded the war to a fixed, unversioned path
(`guacamole.war`). `ansible.builtin.get_url` compares the local file's modification time against
the remote server's `Last-Modified` header — with an unversioned destination, a version bump
could leave `get_url` believing the existing file was already "current" and **skip the
download entirely**, pairing a stale 1.5.5 `guacamole.war` with a freshly-upgraded 1.6.0 JDBC
extension. The result: every login fails with `Extension "guacamole-auth-jdbc-mysql" is not
compatible with this version of Guacamole`. This was a real bug found and fixed during this
project's development (see Chapter 12 for the symptom, and the fix committed as version-qualified
war naming with stale-artifact pruning). It's called out here because a hand-rolled deployment
that reintroduces an unversioned war path will reintroduce the exact same failure mode.

## 7.3 Rollback considerations

**Downgrades are not supported.** Guacamole's JDBC schema upgrade scripts are one-directional —
there is no equivalent `downgrade-*.sql` to reverse a schema change. If an upgrade goes wrong:

- If you have a **pre-upgrade backup** (Chapter 8), the supported path is `guac-restore` from
  that bundle, which reloads both the database and `/etc/guacamole` at the prior version's state.
  This is why "take a backup first" above is not optional for a production upgrade.
- If you don't, restoring a working state means either reverting `guac_version` **and** manually
  reversing whatever schema changes were applied (unsupported, error-prone — not recommended), or
  rebuilding from a known-good backup taken before the upgrade.

## 7.4 The version marker

`/etc/guacamole/.guac_schema_version` is the single source of truth the upgrade logic reads. Do
not hand-edit it. If it's missing entirely (a database that pre-dates this tooling, or one
restored from an external source), the playbook does **not** guess — no upgrade SQL runs, and the
marker is simply stamped at the current `guac_version` on that run. If your database is actually
behind that version's schema when this happens, subsequent operations may behave unexpectedly;
see Chapter 12's entry on schema-version marker mismatches.

## 7.5 Confirming success

```bash
cat /etc/guacamole/.guac_schema_version                       # should read the new version
/usr/local/sbin/guacd -v | head -1                             # should report the new version
ls /etc/guacamole/extensions/ | grep guacamole-auth-jdbc-mysql  # should show only the new version
ls /etc/guacamole/*.war                                         # should show only the new version
bash test/check.sh                                              # full functional check (four services, login)
```

A second `ansible-playbook site.yml` run at the same `guac_version` should report `changed=0` —
this is the idempotence guarantee, and `test/upgrade.sh` asserts it as part of the upgrade test.

## 7.6 Reference test

`test/upgrade.sh [tag] [from_version] [to_version]` (default `ol9 1.5.5 1.6.0`) is the exact,
scripted version of this whole chapter: installs the *from* version in a throwaway Podman
container, bumps `guac_version` to *to*, re-runs, then asserts the schema marker, guacd version,
JDBC jar, and war are all at the new version with no stale-version files left behind, runs
`test/check.sh`, and confirms a same-version re-run is idempotent. Use it to validate any upgrade
path before running it against a real host.
