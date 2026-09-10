# Operations Guide

Day-2 tasks: upgrades, backup/restore, disaster recovery, hardening notes, containers.

---

## Upgrading Guacamole

1. Edit `group_vars/all.yml`:

   ```yaml
   guac_version: "1.6.1"     # the new version — that's the only change
   ```

2. Re-run:

   ```yaml
   ansible-playbook site.yml
   ```

What happens automatically:

- `guacd` is re-downloaded and recompiled (only because the version changed).
- `guacamole.war` and every enabled extension jar are refreshed at the new version.
- Old-version jars and the old exploded webapp / Tomcat work cache are removed.
- Database `schema/upgrade/*.sql` scripts newer than the recorded version are applied in order.
  The applied version is tracked in `/etc/guacamole/.guac_schema_version`.
- Services restart; the playbook verifies `guacadmin` can still log in.

**Before a production upgrade:** take a backup (`guac-backup`) and read the upstream release
notes. Test with `test/upgrade.sh ol9 <old> <new>` (or against a staging host).

Downgrades are **not** supported (schema changes are one-way) — restore from a backup instead.

Also bump `guac_tomcat_version` occasionally to pick up Tomcat security fixes; the old Tomcat
tree is left in place, the `/opt/tomcat` symlink is repointed.

---

## Backups

`guac-backup` is installed on every host and scheduled by `guac-backup.timer`
(`guac_backup_schedule_oncalendar`, default 00:30 daily).

Run one on demand:

```bash
sudo /usr/local/sbin/guac-backup                 # -> /var/backups/guacamole/
sudo /usr/local/sbin/guac-backup --out /mnt/nfs  # somewhere else
```

Each bundle (`guac-backup-<host>-<UTC>.tar.gz`, or `.tar.gz.gpg` when encrypted) contains:

- `database.sql` — full logical dump of the Guacamole database
- `guacamole-home.tar.gz` — all of `/etc/guacamole` (properties, extensions, lib, schema marker)
- `nginx.tar.gz` — `/etc/nginx/ssl` + the proxy site config (if `guac_backup_include_tls`)
- `MANIFEST` — versions, source host, timestamp
- `SHA256SUMS` — integrity of every payload file

There is also a `<bundle>.sha256` sidecar for the bundle itself.

**Copy bundles off the host** (rsync/scp/object storage) — a backup on the same disk is not a
backup. If `guac_backup_gpg_passphrase` is set, store that passphrase somewhere separate and
durable; **without it the bundle cannot be restored.**

---

## Restore / Disaster Recovery

Goal: bring Guacamole back on a **fresh** host (BCP/DR) or roll back a broken one.

1. **Provision the host** with this playbook so all the software and the database exist:

   ```bash
   ansible-playbook -i inventory/hosts.ini site.yml -l newhost
   ```

   Use the *same* `guac_version`, `guac_db_*` and (if applicable) `guac_mysql_host` as the
   original. Do **not** worry about data — the restore replaces it.

2. **Copy the latest bundle** to the new host, e.g. `/root/restore.tar.gz`.

3. **Restore:**

   ```bash
   sudo /usr/local/sbin/guac-restore /root/restore.tar.gz
   ```

   This verifies checksums, stops Tomcat/guacd, moves the current `/etc/guacamole` aside as
   `/etc/guacamole.pre-restore-<ts>`, unpacks the saved config, reloads the database, restores
   the TLS material, restarts services, and waits for Guacamole to answer with HTTP 200.

4. **Verify:** browse the site, log in, confirm your connections and users are present.

For an **encrypted** bundle, set `guac_backup_gpg_passphrase` in the host's vars before step 1
(or export it so `guac-restore` can read it) — the script needs it to decrypt.

`test/dr.sh` runs this whole flow (build on A → backup → restore on B → verify data + login) in
throwaway containers.

### Remote-database DR

If the database is a separate server that survived, you often only need to re-provision the
Guacamole host and point it at the existing DB — no restore required. Restore the
`guacamole-home.tar.gz` portion if you had custom extensions/config:

```bash
sudo tar -C / -xzf <extracted-bundle>/guacamole-home.tar.gz
sudo systemctl restart guacd tomcat
```

---

## Hardening notes

`roles/hardening` (`guac_hardening_enabled`, default on) applies a CIS-aligned baseline on every
supported OS:

- **Kernel/sysctl**: reverse-path filtering, no redirects/source-routing, `tcp_syncookies`,
  `kernel.kptr_restrict=2`, `dmesg_restrict`, `yama.ptrace_scope=1`, `suid_dumpable=0`,
  protected hard/sym links.
- **Modules**: blacklist `cramfs freevxfs jffs2 hfs hfsplus squashfs udf` (L1) and `usb-storage`
  (L2).
- **Core dumps** disabled (limits + systemd-coredump).
- **login.defs**: `PASS_MAX_DAYS 365`, `PASS_MIN_DAYS 1`, `UMASK 027`.
- **SSH** drop-in: no root login, `PermitEmptyPasswords no`, `MaxAuthTries 4`, modern
  KEX/cipher/MAC lists, `X11Forwarding no`; L2 also disables agent/TCP forwarding.
- **File perms** on `passwd/shadow/gshadow/group/sshd_config/crontab`; `cron.allow`/`at.allow`
  restrict scheduling to root.
- **auditd** installed + enabled with a baseline ruleset (identity, sudoers, time, MAC, sshd,
  `/etc/guacamole`, privilege escalation, module load).
- **ctrl-alt-del** reboot masked.
- **App layer**: Tomcat shutdown port disabled, `ErrorReportValve` hides version/stacktraces;
  Nginx `server_tokens off`, HSTS + `X-Content-Type-Options` + `X-Frame-Options` +
  `Referrer-Policy`; optional guacd daemon TLS.
- **TLS 1.3 only** everywhere TLS is terminated or initiated.

**What this is not:** a certified CIS benchmark pass. Full L2 compliance additionally needs a
partition/mount-option layout decided at OS install, AIDE/host-IDS, centralised/remote logging,
time sync policy, and a scanner run (OpenSCAP / CIS-CAT) to confirm. Those are environment
decisions this role deliberately does not force. Set `guac_hardening_level: l1` to drop the
intrusive controls, or `guac_hardening_enabled: false` to skip the role.

### FIPS

`guac_fips_enabled: true` (default **false**):

- **RHEL/Oracle/Rocky/Alma**: runs `fips-mode-setup --enable`. **Reboot required**, then re-run
  the playbook. Verify with `fips-mode-setup --check`.
- **Ubuntu**: requires an Ubuntu Pro subscription — `sudo pro enable fips-updates`, reboot. The
  role only prints a reminder.
- **Debian**: no supported FIPS module; the role does nothing.

Only enable FIPS on hosts you can console into — a misconfigured FIPS transition can prevent SSH.

---

## Container image

```bash
podman build -t guacamole-appliance:local -f container/Containerfile .
podman-compose -f container/docker-compose.yml up -d      # or: docker compose
```

- The image is produced by running the same Ansible roles with `guac_container_build=true`
  (no systemd service management, no firewall/SELinux changes).
- `entrypoint.sh` runs `guacd` + Tomcat as PID 1's children and, on first start, loads the
  schema into the compose MariaDB (using `GUAC_DB_ADMIN_*`).
- Override DB creds and host via environment (`GUAC_DB_HOST`, `GUAC_DB_PASSWORD`, ...); see the
  compose file.
- The image includes `guac-backup`/`guac-restore` but the systemd timer is inert in a container
  — schedule backups from the host (`podman exec <ctr> guac-backup`) or a sidecar cron.

---

## Useful commands on a running host

```bash
systemctl status guacd tomcat nginx mariadb
journalctl -u tomcat -f
sudo /usr/local/sbin/guacd -L debug -f          # foreground guacd debug (stop the service first)
tail -f /opt/tomcat/logs/catalina.out
curl -sk https://localhost/api/tokens -d 'username=guacadmin&password=...'   # smoke-test auth
```
