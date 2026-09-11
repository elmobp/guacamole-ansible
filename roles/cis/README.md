# roles/cis — CIS Benchmark coverage (Level 1 + Level 2)

Native implementation of the CIS Benchmark control set for the nine platforms
this project supports. Wired into `site.yml` as its own role step, immediately
after `roles/hardening` and before `roles/connections`, guarded by
`when: guac_cis_enabled | bool`.

That position is deliberate. `roles/hardening` owns the baseline drop-ins
(`50-guac-hardening` for sshd, `90-guac-hardening` for sysctl and audit rules)
and this role layers the rest of the benchmark on top in separate,
higher-numbered files. It also has to run after every package install in the
play: the generated audit rule set is derived from the setuid binaries actually
present on the host, so moving it earlier makes converge 1 and converge 2
disagree and breaks the `changed=0` idempotence gate. `roles/connections`, which
runs after it, only touches the database.

Full narrative documentation, benchmark versions, the deviation register and the
OpenSCAP workflow: **[`docs/CIS.md`](../../docs/CIS.md)**.

## Layout

| Path | Covers |
|---|---|
| `tasks/section1_initial_setup.yml` | 1.x — kernel modules, mounts, package auth, SELinux/AppArmor, bootloader, process hardening, crypto policy, banners |
| `tasks/section2_services.yml` | 2.x — server services, client packages, time sync, cron/at |
| `tasks/section3_network.yml` | 3.x + 4.x — sysctl parameters and the host firewall |
| `tasks/section5_access_auth.yml` | 5.x — sshd, sudo, PAM (pwquality/faillock/pwhistory), user accounts |
| `tasks/section6_logging_audit.yml` | 6.x — AIDE, journald, rsyslog, logrotate, auditd |
| `tasks/section7_system_maintenance.yml` | 7.x — file permissions, account consistency, findings report |
| `vars/RedHat.yml`, `vars/Debian.yml` | package names, service names and paths per OS family |

## Toggles

Set these in `group_vars/all.yml` (a CIS block is already there) or in
`host_vars/<host>.yml`.

| Variable | Default | Meaning |
|---|---|---|
| `guac_cis_enabled` | `true` | Run this role at all. |
| `guac_cis_level` | `l2` | `l1` or `l2`. `l2` adds the Level 2 controls on top of Level 1. |
| `guac_cis_exclusions` | 9 entries | CIS control IDs that are **not** remediated. Prefix matched. |

Everything else lives in `defaults/main.yml` and is documented inline.

## How exclusions work

`tasks/main.yml` compiles `guac_cis_exclusions` into a single anchored regex,
`cis_skip_re`, so each control guard is one readable expression:

```yaml
when: not ('2.1.22' is search(cis_skip_re))
```

The regex requires the next character after the prefix to be `.` or end-of-string,
so excluding `1.1.2` also excludes `1.1.2.1.3` but never `1.1.22`. An empty list
matches nothing.

## Guard rails

This role must never take the Guacamole service down. Three mechanisms enforce that:

- `guac_cis_protected_services` and `guac_cis_package_keep` are subtracted from
  every package-removal list, so nginx, Tomcat, guacd, MariaDB and sshd can never
  be uninstalled by a benchmark control.
- `guac_cis_required_ports` (22/80/443) is re-asserted against firewalld/ufw after
  the firewall controls run. No second firewall is installed and no default policy
  is set that would cut loopback traffic (nginx → Tomcat → guacd is all on `lo`).
- Control `2.1.22` ("a web server must not be installed") is excluded by default
  and SELinux is only switched to enforcing in the config file, not on the running
  kernel, unless `guac_cis_selinux_setenforce_now` is set.

## Idempotence notes

The project gates on `changed=0` for a second converge. Things that were easy to
get wrong here and are deliberately written the way they are:

- `/etc/cron.allow`, `/etc/at.allow`, `/etc/crontab` and the `login.defs` keys are
  also written by `roles/hardening`. Both roles write **identical** values; two
  tasks disagreeing over one file is the classic way to lose the gate.
- The audit rule set enumerates setuid binaries at run time. That enumeration is
  the last package-dependent step in the role, so converge 1 and converge 2 see
  the same binary set.
- The findings report carries no timestamp.
- `aide --init` is guarded with `creates:` and skipped inside containers.
- `ufw` has no idempotent query worth parsing, so its commands use
  `changed_when: false` — matching what `roles/common` already does.
