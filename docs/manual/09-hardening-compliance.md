# 9. Hardening and Compliance

`roles/hardening` (`guac_hardening_enabled: true`, on by default) applies a CIS-aligned baseline
on every supported OS. This chapter covers what it does operationally and where to look for
formal compliance detail — it deliberately does **not** duplicate the full CIS control-by-control
mapping or the Australian ISM mapping; those live in their own documents.

## 9.1 What's applied

| Area | Detail |
|---|---|
| Kernel / sysctl | Reverse-path filtering, no ICMP redirects/source-routing, martian logging, `tcp_syncookies`, ASLR (`kernel.randomize_va_space=2`), `kernel.kptr_restrict=2`, `dmesg_restrict`, `yama.ptrace_scope=1`, `suid_dumpable=0`, protected hard/symlinks. |
| Kernel modules | Blacklists `cramfs freevxfs jffs2 hfs hfsplus squashfs udf` at L1; adds `usb-storage` at L2. |
| Core dumps | Disabled via both `limits.d` and `systemd-coredump` (`Storage=none`). |
| `login.defs` | `PASS_MAX_DAYS 365`, `PASS_MIN_DAYS 1`, `PASS_WARN_AGE 7`, `UMASK 027`. |
| SSH | Drop-in at `/etc/ssh/sshd_config.d/50-guac-hardening.conf`: no root login (`guac_hardening_ssh_permit_root`), `PermitEmptyPasswords no`, `MaxAuthTries 4`, modern KEX/cipher/MAC lists, `X11Forwarding no`; **L2 additionally** disables agent and TCP forwarding. |
| File permissions | Locks down `passwd`, `shadow`, `gshadow`, `group`, `sshd_config`, `crontab`; `cron.allow`/`at.allow` restrict job scheduling to root. |
| Time sync | `chrony`, enabled and started (`guac_hardening_time_sync: true`) — accurate time matters for TLS validity windows, TOTP codes, and audit log correlation. |
| `auditd` | Installed and enabled with a baseline ruleset covering identity changes, sudoers, time changes, MAC (SELinux/AppArmor) changes, `sshd` config, `/etc/guacamole`, privilege escalation, and module loads. |
| Misc | `ctrl-alt-del.target` masked (no accidental reboot from console); optional automatic security patching (`guac_auto_patch`, off by default — deliberately, so patching stays under change control unless you opt in). |
| App layer | Tomcat shutdown port disabled, `conf`/`bin` locked to `0750`, `ErrorReportValve` hides version/stack traces on error pages; nginx `server_tokens off`, HSTS, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, a Content-Security-Policy; optional guacd daemon-side TLS (`guac_guacd_tls_enabled`). |
| TLS | **1.3 only**, everywhere this stack terminates or initiates TLS (nginx, and guacd↔webapp if enabled) — see Chapter 6. |

`guac_hardening_level: l1` drops the more intrusive L2-only controls (SSH agent/TCP forwarding,
`usb-storage` blacklist) for hosts where those would break a legitimate workflow.
`guac_hardening_enabled: false` skips the role entirely (not recommended outside throwaway labs).

## 9.2 What this baseline is not

This is a strong baseline, **not a certified CIS benchmark pass**. Achieving full CIS L2
additionally needs things this role deliberately does not force, because they're environment
decisions: a partition/mount-option layout (decided at OS install time), a host intrusion
detection system (AIDE or equivalent), and a scanner run (OpenSCAP / CIS-CAT) to confirm the
result. **For the full CIS-benchmark control-by-control coverage, gap analysis, and OpenSCAP
scoring, see `docs/CIS.md`.** That document is the authoritative compliance artifact; this
chapter only describes what the `hardening` role itself does at runtime.

## 9.3 FIPS mode (opt-in)

```yaml
guac_fips_enabled: true   # default: false
```

| Platform | Behaviour |
|---|---|
| RHEL / Oracle / Rocky / Alma | Runs `fips-mode-setup --enable`. **Requires a reboot**, then re-run the playbook to finish verification. Confirm with `fips-mode-setup --check`. |
| Ubuntu | Requires an Ubuntu Pro subscription (`sudo pro enable fips-updates`), then a reboot. The role only prints a reminder — it cannot enable Ubuntu Pro on your behalf. |
| Debian | No supported FIPS module; the role does nothing. |

**Only enable FIPS on a host you can reach via console/out-of-band access.** A FIPS transition
that goes wrong on a platform that isn't prepared for it can prevent SSH from coming back up —
this is the one hardening toggle in this project capable of locking you out.

## 9.4 Central log forwarding

```yaml
guac_syslog_target: "collector.example.com:6514"   # empty (default) = no forwarding
guac_syslog_protocol: "tcp"                         # tcp | udp
guac_syslog_tls: true                               # TLS-wrap the stream (recommended)
guac_syslog_relp: false                             # use RELP (reliable) instead of plain omfwd
guac_syslog_tls_permitted_peer: "collector.example.com"   # expected collector CN/SAN
guac_syslog_tls_ca: "{{ vault_syslog_ca_pem }}"
guac_syslog_tls_cert: "{{ vault_syslog_client_cert_pem }}"   # optional — mutual TLS
guac_syslog_tls_key: "{{ vault_syslog_client_key_pem }}"
```

When `guac_syslog_target` is set, `rsyslog` (plus `rsyslog-gnutls` for TLS and `rsyslog-relp` for
RELP, installed automatically as needed) forwards this host's logs — including `auditd` events,
via the syslog plugin — to the named collector. Plain TCP/UDP remains available for a lab or a
collector that doesn't support TLS, but **TLS is the recommended path** for anything handling
real credentials or session metadata. Setting both `guac_syslog_tls_cert` and `_key` enables
mutual TLS (the collector authenticates this host as well as vice versa).

**Verify the forwarded stream is actually TLS 1.3:**

```bash
openssl s_client -connect collector.example.com:6514 -tls1_3 </dev/null 2>&1 | grep -i protocol
```

## 9.5 auditd

The baseline ruleset (`/etc/audit/rules.d/90-guac-hardening.rules`) watches identity files,
`sudoers`, time changes, SELinux/AppArmor policy changes, `sshd_config`, all of `/etc/guacamole`,
privilege-escalation syscalls, and kernel module load/unload. Query it with:

```bash
sudo ausearch -k <key>      # keys are named in the rules file
sudo aureport --summary
```

## 9.6 Where to go for formal compliance

| Need | Document |
|---|---|
| CIS benchmark control-by-control mapping, OpenSCAP scoring, accepted deviations | `docs/CIS.md` |
| Australian ISM control mapping, low-level design for a RHEL/IRAP-style build, POA&M | `docs/LLD-RHEL-IRAP.md`, `docs/ISM.md` |
| Every network flow (for a firewall change request) | `docs/FIREWALL.md` (also Chapter 10) |

This manual's role is to tell you *how to operate* the hardened system day to day — starting,
checking, and adjusting the controls above — not to re-litigate the compliance mapping itself.
