# CIS Benchmark Coverage

How this project implements the CIS Benchmarks, what it deliberately does **not** implement and
why, and how to read and ratchet the automated compliance score.

Implementation: **[`roles/cis/`](../roles/cis/)** (see its
[README](../roles/cis/README.md) for the file-by-file layout).
Toggles: **[`group_vars/all.yml`](../group_vars/all.yml)** § *CIS Benchmark*.
CI gate: **[`.github/workflows/compliance.yml`](../.github/workflows/compliance.yml)**.

> **Scope note.** A benchmark score is evidence, not compliance. This role gets the host to a
> defensible baseline and makes every gap explicit. It does not, and cannot, decide which gaps
> your accreditation authority will accept. Read [Exclusions](#exclusions--deliberate-deviations)
> before you take the number to an assessor.

---

## Quick start

```yaml
# group_vars/all.yml
guac_cis_enabled: true      # run the role at all
guac_cis_level: "l2"        # l1 | l2
guac_cis_exclusions:        # control IDs NOT remediated (prefix matched)
  - "1.1.2"
  # ... see below
```

```bash
ansible-playbook site.yml --tags cis      # just the benchmark controls
ansible-playbook site.yml                 # the whole build, CIS included
```

The role runs as its own step in `site.yml`, immediately after `hardening` and before
`connections`. It is toggled independently of `guac_hardening_enabled`: `hardening` lays down a
small opinionated baseline that every host gets, `cis` layers the rest of the benchmark on top.

---

## Benchmark versions per OS

The control IDs used throughout `roles/cis` follow the **CIS Red Hat Enterprise Linux 9
Benchmark v2.x** section numbering. CIS restructured its Linux benchmarks around that numbering,
so Debian 12 and Ubuntu 22.04/24.04 v2.x line up with very little drift.

| Platform | Benchmark tracked | Notes |
|---|---|---|
| RHEL / Oracle / Rocky / Alma **9** | CIS Red Hat Enterprise Linux 9 Benchmark, v2.x | The reference numbering for this role. OL/Rocky/Alma are binary-compatible rebuilds; CIS publishes separate Oracle/Rocky documents whose section numbering matches. |
| RHEL / Oracle / Rocky / Alma **10** | CIS Red Hat Enterprise Linux 10 Benchmark, v1.x | Very close to the RHEL 9 v2.x structure. Where a control has no RHEL 10 equivalent yet, the RHEL 9 remediation is applied — it is a superset, not a conflict. |
| Debian **12** | CIS Debian Linux 12 Benchmark, v1.x | Section numbering aligned to the RHEL 9 v2.x scheme. |
| Debian **13** | *no published CIS benchmark at time of writing* | Treated as Debian 12 + the Debian-family variable set. Re-check when CIS publishes. |
| Ubuntu **22.04 LTS** | CIS Ubuntu Linux 22.04 LTS Benchmark, v2.x | |
| Ubuntu **24.04 LTS** | CIS Ubuntu Linux 24.04 LTS Benchmark, v1.x | |
| Ubuntu **26.04 LTS** | *no published CIS benchmark at time of writing* | Treated as Ubuntu 24.04. Note 26.04 no longer ships `/var/log/lastlog` or `/var/log/wtmp`; the audit rule set stats every optional watch path before emitting it, because `auditctl` rejects a watch on a missing path *and silently discards the rest of the file*. |

**Confirm the exact minor version against the CIS Workbench before you cite one in an audit
report.** CIS reissues these documents, sometimes renumbering controls; the versions above are
what the role was written against, not a guarantee of what is current today. `roles/cis` prints
the benchmark name it believes it is applying at the start of every run.

### Where the numbering drifts

| Area | RHEL family | Debian family |
|---|---|---|
| Mandatory access control (1.3) | SELinux — `/etc/selinux/config`, `targeted` policy, `setenforce` | AppArmor — `apparmor=1 security=apparmor` on the kernel command line, `aa-enforce` |
| PAM stack (5.3) | `authselect` features (`with-faillock`, `with-pwhistory`, `without-nullok`) | `pam-auth-update` profiles in `/usr/share/pam-configs/` |
| Host firewall (4.x) | `firewalld` | `ufw` |
| Password hashing (5.4.1) | `ENCRYPT_METHOD SHA512` | `ENCRYPT_METHOD YESCRYPT` |
| Bootloader (1.4) | `/boot/grub2/user.cfg`, `grub2-mkconfig` | `/etc/grub.d/40_custom*`, `update-grub` |
| Filesystem integrity (6.1) | `aide --init` then activate `aide.db.new.gz` | `aideinit` (writes and installs `aide.db` in one step) |

All of this is resolved in `roles/cis/vars/RedHat.yml` and `roles/cis/vars/Debian.yml`. Task
files never branch on a distro name beyond `ansible_os_family`.

---

## What L1 and L2 mean here

`guac_cis_level` selects the CIS **Server** profile, not the Workstation profile.

**Level 1 (`guac_cis_level: "l1"`)** — controls that are practical on essentially any server and
are not expected to break anything: kernel module blacklists, package authenticity, SELinux /
AppArmor enabled, banners, core dumps off, sysctl hardening, removal of unused server and client
packages, cron/at restricted to an allow list, sshd hardening, sudo defaults, password quality
and lockout, `login.defs` ageing policy, journald/rsyslog/logrotate, auditd with the full rule
set, AIDE, and the section 7 file-permission set.

**Level 2 (`guac_cis_level: "l2"`, the default)** — everything in L1 **plus** controls that
trade convenience or functionality for defence in depth:

| L2-only control | What it does here | Why it is safe on this appliance |
|---|---|---|
| `usb-storage`, `bluetooth`, `firewire-core`, `thunderbolt` module blacklist | Physical-media and peripheral attack surface removed | A jump host has no legitimate use for any of these. |
| `DisableForwarding yes` in sshd | Turns off *all* SSH forwarding (TCP, agent, X11, stream-local) | Guacamole never uses inbound SSH forwarding — `guacd` makes its **outbound** SSH/RDP/VNC connections with its own client libraries, which this does not touch. `roles/hardening` already disables TCP and agent forwarding at its own L2. |
| `pam_wheel` on `su` (5.4.2) | Restricts `su(1)` to members of `guac_cis_su_group`, which is created **empty** | `pam_wheel` always lets uid 0 through, so `root` and `sudo -i` keep working. Privilege escalation goes through `sudo`, which stays fully functional. |
| Wireless interfaces disabled (3.1.2) | `nmcli radio all off` | No server build needs Wi-Fi. |
| AppArmor profiles forced to enforce (1.3.1.4) | **Off by default** — see [Exclusions](#exclusions--deliberate-deviations) | |

Anything more intrusive than the above is an opt-in variable rather than an L2 default,
precisely so that `guac_cis_level: "l2"` is a setting you can actually leave on.

---

## Exclusions — deliberate deviations

`guac_cis_exclusions` is a list of control IDs the role will **not** remediate. Matching is by
prefix, anchored, and requires the next character to be `.` or end-of-string — so excluding
`1.1.2` also excludes `1.1.2.1.3`, but never `1.1.22`. An empty list matches nothing.

Every default entry is justified below. **Do not remove one without reading its row** — several
exist to keep Guacamole serving traffic, and removing them will take the service down.

### Excluded by default

| Control | Title (abbrev.) | Why it is excluded | How to comply anyway |
|---|---|---|---|
| **1.1.2** | Separate partitions and mount options for `/tmp`, `/var`, `/var/tmp`, `/var/log`, `/var/log/audit`, `/home` | A host that is already provisioned cannot be repartitioned from a config-management run, and a half-applied `fstab` change is a host that does not boot. This is a **build-time** decision, not a converge-time one. | Partition at install/kickstart/cloud-init time. The role still *reports* which of these are not separate partitions in the findings file, so the gap is visible. Setting `guac_cis_manage_mounts: true` applies the mount **options** (`nodev,nosuid,noexec` on `/dev/shm`) to mount points that already exist. |
| **1.4.1** | Bootloader password | Needs an operator-supplied secret; there is no safe default, and a wrong value locks you out of single-user recovery. | Generate a hash with `grub2-mkpasswd-pbkdf2` (RHEL) or `grub-mkpasswd-pbkdf2` (Debian), set `guac_cis_grub_password_hash`, and remove `"1.4.1"` from the exclusion list. Physical/console access control is often handled by the hypervisor or DC instead — record whichever applies. |
| **1.6.2** | FIPS-validated cryptography | Owned by `guac_fips_enabled` in `roles/hardening`, which is a separate, reboot-requiring, platform-dependent decision (RHEL: `fips-mode-setup`; Ubuntu: needs Ubuntu Pro; Debian: unsupported). Two roles fighting over the crypto policy is worse than one owning it. | Set `guac_fips_enabled: true` and reboot. See `docs/CONFIGURE.md`. |
| **1.8** | GNOME Display Manager settings | No desktop environment is ever installed on this appliance, so every control in 1.8 is vacuous. OpenSCAP correctly reports these as `notapplicable`. | Nothing to do. |
| **2.1.22** | "A web server is not installed" | **This host *is* the web server.** It exists to serve the Guacamole UI over nginx and Tomcat. Remediating this control uninstalls the product. | Accept and document. The compensating controls are the whole of `roles/nginx_proxy` (TLS 1.3 only, HSTS, security headers, no direct 8080 exposure) and `roles/hardening`'s app layer. |
| **3.1.1** | Disable IPv6 | Breaks dual-stack deployments, and an IPv6-only or dual-stack client subnet is not unusual. Disabling IPv6 on a bastion is also a good way to lose remote access to it. | The role still applies every IPv6 *hardening* sysctl (no forwarding, no router advertisements, no redirects, no source routing) — so IPv6 is present but locked down. Set `net.ipv6.conf.all.disable_ipv6` yourself if your environment is genuinely v4-only. |
| **6.3.3.21** | auditd rule set is immutable (`-e 2`) | Once loaded, the rule set cannot be changed until the next reboot. That makes the very next `ansible-playbook site.yml` unable to converge the audit rules, which breaks the project's `changed=0` idempotence gate and, more importantly, means an urgent audit-rule fix needs a reboot of the bastion. | Set `guac_cis_auditd_immutable: true` **and** remove `"6.3.3.21"` from the exclusion list. Do this last, on a host you are not going to reconfigure — e.g. as the final step before handing the system over. |
| **7.1.11** | No world-writable files exist | A blind `chmod -R o-w` sweep across a live host is how you break MariaDB's datadir, a mounted volume or a sticky-bit directory at 3am. | **Audited unconditionally** — the findings are written to `guac_cis_audit_report_path` (`/var/log/guac-cis-audit.txt`) every converge. Review them, fix the real ones by hand, then remove the exclusion if you want enforcement. |
| **7.1.12** | No unowned or ungrouped files exist | Same reasoning: `chown -R root:root` over whatever a `find / -nouser` returns is unbounded blast radius, and the usual real cause is a UID mismatch on a mounted volume that you want to fix at the source. | Audited and reported exactly as 7.1.11. |

### Implemented, but defaulted to the less intrusive compliant option

These are **not** in the exclusion list — the control is remediated — but a judgement call was
made about *how*. Each is a variable you can change.

| Control | Variable | Default | Reasoning |
|---|---|---|---|
| 1.3.1.5 — SELinux enforcing | `guac_cis_selinux_setenforce_now` | `false` | `SELINUX=enforcing` **is** written to `/etc/selinux/config`, so the host comes up enforcing on the next boot. Flipping a *running* host from permissive to enforcing mid-play can break the nginx → Tomcat proxy before `roles/common`'s SELinux booleans have been audited, and you find out when the login page stops loading. Set to `true` once you have converged and rebooted at least once cleanly. |
| 1.3.1.4 — all AppArmor profiles enforcing | `guac_cis_apparmor_enforce_profiles` | `false` | `aa-enforce` over every shipped profile can confine nginx and MariaDB in ways this stack has not been validated against. Turn it on deliberately, then re-run `test/check.sh`. |
| 5.3.3.1 — account lockout (Debian family) | `guac_cis_pam_faillock_debian` | `false` | On RHEL the PAM stack is edited through `authselect`, which is transactional and reversible. On Debian/Ubuntu it means editing the shared `pam-auth-update` stack, where a mistake locks **every** account out of the box — including yours, on a bastion. The profile is installed and ready; flipping the switch is a one-liner. This project cannot integration-test a PAM lockout, and shipping an untested lockout as a default is worse than the finding. RHEL-family hosts get faillock by default. |
| 6.3.2 — auditd disk-full behaviour | `guac_cis_auditd_admin_space_left_action`, `..._disk_full_action`, `..._disk_error_action` | `single` | CIS accepts `halt` or `single`. `halt` powers the jump host off the moment `/var/log/audit` fills — on a bastion that means locking every operator out simultaneously, during what is usually a logging incident rather than a security one. `single` is the less destructive compliant option. Change to `halt` if your accreditation demands it. |
| 1.1.2 mount options | `guac_cis_manage_mounts` | `false` | See the 1.1.2 row above. |

### Guard rails that override the benchmark

Three mechanisms exist purely to stop a benchmark control taking Guacamole down. They are not
optional and they are not exclusions — they constrain how the controls are applied.

- **`guac_cis_protected_services`** (`nginx, tomcat, guacd, mariadb, mysqld, sshd, ssh`) and
  **`guac_cis_package_keep`** are subtracted from every package-removal list. No section 2
  control can uninstall the product.
- **`guac_cis_required_ports`** (`22/tcp, 80/tcp, 443/tcp`) is re-asserted against
  `firewalld`/`ufw` after the section 4 controls run. `roles/common` already opens these; the
  CIS role confirms rather than replaces them, never installs a second firewall, and never sets
  a policy that would cut the nginx → Tomcat → `guacd` path (all of which is loopback traffic —
  hence the `allow in on lo` rules preceding `deny in from 127.0.0.0/8`).
- The sudo `secure_path` keeps `/usr/local/sbin:/usr/local/bin`. `guacd` is compiled to
  `/usr/local/sbin/guacd` on this host; the stock CIS example value omits those directories.

---

## Reading the OpenSCAP report

`.github/workflows/compliance.yml` builds a real host, scans it, and publishes two artifacts per
platform:

| Artifact file | What it is |
|---|---|
| `oscap-report-<tag>.html` | The human-readable report. Open it in a browser. |
| `oscap-results-<tag>.xml` | Raw XCCDF results — the machine-readable source of the score, and what you hand an assessor. |
| `oscap-target-<tag>.txt` | Which datastream file and which profile id were actually evaluated. Check this first when a score moves unexpectedly. |

To reproduce a scan by hand on a built host:

```bash
# RHEL family
dnf -y install openscap-scanner scap-security-guide
# Debian / Ubuntu
apt-get install -y openscap-scanner ssg-base ssg-debian ssg-debderived   # names vary by release

DS=/usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml    # or ssg-ol9, ssg-debian12, ssg-ubuntu2404
oscap info --profiles "$DS"                            # list the profile ids this content offers

oscap xccdf eval \
  --profile xccdf_org.ssgproject.content_profile_cis \
  --results /tmp/results.xml --report /tmp/report.html \
  "$DS"
```

`oscap` exit codes: **0** every rule passed, **1** the scanner itself errored, **2** the scan ran
and at least one rule failed. **2 is the normal outcome** — do not treat it as a broken scan.

### Interpreting a result

Each rule lands in one of these states. Only `pass` and `fail` move the score.

| Result | Meaning | What to do |
|---|---|---|
| `pass` | Remediated. | Nothing. |
| `fail` | Not remediated. | Cross-check the rule id against [Exclusions](#exclusions--deliberate-deviations). If it maps to a documented deviation, it is expected — record it. If it does not, it is a **regression**: fix it in `roles/cis`. |
| `notapplicable` | The rule's platform test did not match (e.g. every 1.8 GNOME rule on a headless host). | Nothing. Excluded from the score. |
| `notchecked` / `notselected` | No automated check exists, or the profile does not select it. | Manual attestation if your assessor needs the control covered. |
| `error` / `unknown` | The check itself broke. | Investigate — this is usually missing content or a probe that cannot run in a container, not a finding. |

The CI job prints every failing rule id as a collapsed log group, so a regression is diagnosable
from the job log without downloading the artifact.

### Why the score will never be 100

A meaningful fraction of SSG's CIS rules are unachievable on this appliance **by design**: it is
a web server (2.1.22), it cannot be repartitioned from a converge (1.1.2), the bootloader
password needs an operator secret (1.4.1), and the auditd rule set is deliberately mutable
(6.3.3.21). SSG's rule set is also not a 1:1 mapping of the CIS document — it carries rules from
other baselines that the CIS profile selects, and its idea of a control's scope occasionally
differs from the role's. **A stable score with a fully explained delta is the goal, not 100.**

---

## Raising the CI threshold

`CIS_SCORE_THRESHOLD` in `.github/workflows/compliance.yml` starts at **80**. It is a ratchet,
not a target.

1. Let the workflow run and read the published score for each platform.
2. If a score sits comfortably above the threshold, raise the threshold to just below the
   observed value — observed 91 → set 88. The few points of headroom absorb SSG content updates
   without turning every content refresh into a red build.
3. Repeat. The threshold should only ever move up.

**Never lower the threshold to make a red build green.** A drop means one of three things:

- a genuine regression in `roles/cis` → fix the task;
- a control you have decided not to meet → add it to `guac_cis_exclusions` **and** add a row to
  [Exclusions](#exclusions--deliberate-deviations) explaining why. *An exclusion that is not in
  this document is a bug*;
- new or renumbered rules in an SSG content update → confirm against the current benchmark, then
  either remediate or document, and re-baseline the threshold deliberately, in its own commit,
  with the reason in the commit message.

The workflow also runs weekly on a schedule precisely to catch the third case early, rather than
discovering it in the middle of an unrelated pull request.

---

## Why not ansible-lockdown

The obvious alternative was to vendor the upstream `ansible-lockdown` `RHEL9-CIS`, `UBUNTU24-CIS`
and `DEBIAN12-CIS` roles and layer exceptions on top. That was evaluated and rejected:

- **Platform coverage.** There is no upstream role for Debian 13 or Ubuntu 26.04 — two of the
  nine platforms this project supports. Two of nine uncovered means maintaining a native
  implementation for those anyway, and then maintaining two different mechanisms.
- **Idempotence.** This project gates hard on `changed=0` for a second converge, on every
  platform, in CI. The upstream roles are not written to that standard, and bringing a vendored
  copy up to it means forking it — at which point the "upstream" benefit is gone.
- **Tuning surface.** They expose several hundred tunables, a large number of which must be set
  correctly just to stop the benchmark tearing down the web stack this host exists to serve.
  The result would have been a variable file longer than the native implementation, with the
  actual behaviour spread across someone else's task files.
- **Traceability.** Every remediation here is one task, named with its control ID, greppable, and
  guarded by one readable expression (`when: not ('2.1.22' is search(cis_skip_re))`). For an
  assessor conversation, that is worth considerably more than a dependency.

The trade-off accepted in return: CIS renumbering between benchmark revisions has to be tracked
by hand. The OpenSCAP gate is the mitigation — it scores against SSG's current content, so a
renumbering or a newly-added rule shows up as a score drop rather than as silent drift.

---

## See also

- [`docs/CONFIGURE.md`](CONFIGURE.md) § Hardening — every CIS variable, one line each
- [`docs/OPERATIONS.md`](OPERATIONS.md) — day-2 hardening operations
- [`docs/FIREWALL.md`](FIREWALL.md) — the port matrix the firewall guard rail protects
- [`docs/LLD-RHEL-IRAP.md`](LLD-RHEL-IRAP.md) — Australian ISM control mapping
- [`roles/cis/README.md`](../roles/cis/README.md) — implementation layout and idempotence notes
