# 8. Backup, Restore, and Disaster Recovery

`guac-backup` and `guac-restore` are installed on every host by the `backup` role
(`guac_backup_enabled: true`, the default) and are the supported path for both routine backups
and full disaster recovery.

## 8.1 Scheduled and on-demand backups

A systemd timer, `guac-backup.timer`, runs `guac-backup` on the schedule in
`guac_backup_schedule_oncalendar` (default `*-*-* 00:30:00`, i.e. 00:30 daily,
systemd `OnCalendar` syntax):

```bash
systemctl list-timers guac-backup.timer
sudo systemctl status guac-backup.timer
```

Run one immediately, any time:

```bash
sudo /usr/local/sbin/guac-backup                 # -> /var/backups/guacamole/ (guac_backup_dir)
sudo /usr/local/sbin/guac-backup --out /mnt/nfs  # to an alternate/mounted destination
```

## 8.2 Bundle contents

Each run produces `guac-backup-<hostname>-<UTC-timestamp>.tar.gz` (or `.tar.gz.gpg` when
encrypted — §8.4), containing:

| File | Contents |
|---|---|
| `database.sql` | A full `mysqldump` of the Guacamole database (`--single-transaction`, no locks — safe against a live system). |
| `guacamole-home.tar.gz` | All of `/etc/guacamole` — `guacamole.properties`, every extension jar, `lib/`, and the schema-version marker. |
| `nginx.tar.gz` | `/etc/nginx/ssl` plus `/etc/nginx/conf.d/guacamole.conf` — only present when `guac_backup_include_tls: true` (the default). |
| `MANIFEST` | Source host, UTC timestamp, OS, Guacamole/Tomcat versions, DB mode (local or remote host). |
| `SHA256SUMS` | Checksum of every file above, verified automatically during restore. |

A `<bundle>.sha256` sidecar file sits next to the bundle itself (checksum of the whole tarball,
independent of the per-file `SHA256SUMS` inside it) — verify a bundle hasn't been corrupted in
transit with `sha256sum -c <bundle>.sha256`.

## 8.3 Copy bundles off the host

**A backup on the same disk as the system it protects is not a backup.** Ship every bundle
somewhere else — rsync, `scp`, or object storage — as part of your normal file-transfer tooling;
this is deliberately left as "your normal tooling" rather than baked into the script, since every
environment's approved transfer path differs. See `docs/FIREWALL.md` O13 for the egress this
implies.

## 8.4 Encryption at rest

```yaml
guac_backup_gpg_passphrase: "{{ vault_backup_passphrase }}"
```

When set, every bundle is symmetrically encrypted with GPG (AES-256, `--cipher-algo AES256`)
immediately after creation, and the plaintext `.tar.gz` is deleted — only the `.tar.gz.gpg` (and
its own `.sha256`) remain on disk.

**Store the passphrase somewhere separate and durable from the backups themselves** (a password
manager, a vault distinct from the one storing infrastructure secrets used day-to-day, or a
sealed physical record) — **without it, an encrypted bundle cannot be restored, ever.** This is
the single most important operational fact in this chapter.

## 8.5 Restore onto the *same* host (roll back a broken change)

```bash
sudo /usr/local/sbin/guac-restore /path/to/guac-backup-<host>-<ts>.tar.gz[.gpg]
```

`guac-restore`:

1. Decrypts the bundle if it's `.gpg` (needs `guac_backup_gpg_passphrase` set or exported).
2. Verifies `SHA256SUMS` against the bundle's contents.
3. Stops `tomcat` and `guacd`.
4. Moves the current `/etc/guacamole` aside as `/etc/guacamole.pre-restore-<UTC-timestamp>` (never
   silently overwritten — you can always recover what was there before the restore).
5. Unpacks the saved `/etc/guacamole` tree, reloads the database from `database.sql`, and (if
   present in the bundle) restores the nginx TLS/site config.
6. Restarts `guacd` and `tomcat`, then polls until Guacamole answers HTTP 200.

## 8.6 BCP/DR runbook — restoring onto a fresh host

This is the drill to rehearse *before* you need it for real, and mirrors `test/dr.sh` exactly:

1. **Provision the new host** with this same playbook, so every package, service account, and
   database exist — don't worry about data, the restore replaces it:

   ```bash
   ansible-playbook -i inventory/hosts.ini site.yml -l newhost
   ```

   Use the **same** `guac_version`, `guac_db_*`, and (if a separate DB server was in use) the same
   `guac_mysql_host` as the host you're recovering. A version mismatch between the backup's schema
   and the freshly-provisioned software is not supported — provision at the version the backup
   was taken at, then upgrade afterwards if needed (Chapter 7).

2. **Copy the latest bundle** to the new host (e.g. `/root/restore.tar.gz`), from wherever you
   shipped it in §8.3.

3. **Restore:**

   ```bash
   sudo /usr/local/sbin/guac-restore /root/restore.tar.gz
   ```

4. **Verify:** browse to the new host's URL, log in, and confirm your connections, groups, and
   users are all present as expected.

### Remote-database variant

If the database itself is a separate server that survived whatever took out the Guacamole host,
you often don't need a database restore at all — just re-provision the Guacamole host pointed at
the existing DB. Restore only the `guacamole-home.tar.gz` portion if you had custom
extensions/config beyond what Ansible would regenerate:

```bash
sudo tar -C / -xzf <extracted-bundle>/guacamole-home.tar.gz
sudo systemctl restart guacd tomcat
```

## 8.7 RTO / RPO

These are environment-dependent — put real numbers here for your deployment — but the mechanics
that bound them are:

- **RPO (recovery point objective)** is bounded by your backup cadence
  (`guac_backup_schedule_oncalendar`, default daily) plus how far behind your offsite copy step
  runs. Tighten the `OnCalendar` schedule and/or the offsite-copy frequency to shrink this.
- **RTO (recovery time objective)** is bounded by: time to provision a fresh host with
  `site.yml` (roughly 5–15 minutes per `docs/INSTALL.md`, since guacd compiles from source) +
  time to copy the bundle to that host + `guac-restore`'s own runtime (database import size
  dominates; typically under a minute for a modest connection/user count). Rehearsing the drill in
  §8.6 on a realistic bundle size is the only reliable way to know your actual number.

## 8.8 Reference test

`test/dr.sh [tag]` (default `ol9`) automates the exact flow above in throwaway Podman containers:
full build on host A, create a marker connection, `guac-backup`, stream the bundle to a freshly
provisioned host B, `guac-restore`, then confirm `guacadmin` can log in on B **and** that the
marker connection is present. Run it whenever you change anything in `roles/backup/` or want
confidence in the DR path before a real incident.
