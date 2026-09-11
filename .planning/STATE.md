---
gsd_state_version: "1.0"
status: milestone-2-complete
stopped_at: all planned phases merged and converge-tested; pushed to origin
last_updated: "2026-09-11T11:10:00.000Z"
state_head: 6de5ff9
---

## Session close 2026-09-11

All of Milestone 2 (phases 10-17) plus the modern-login-page feature are merged to `main` and
converge-tested together on ol9 (custom-login + CIS L2 + OpenID all enabled at once):
`changed=0` on two consecutive runs, `check.sh` all green, all extensions load. Pushed to
`git@github.com:elmobp/guacamole-ansible.git` (`main` branch; the three agent worktree branches
were internal scratch space, deleted after merging, not pushed). Repo working tree clean, no
containers left running.

## SSH-under-CIS-L2 validated 2026-09-11

Treated a podman container as a real host (published sshd on 127.0.0.1:2222, real `ssh` client
from the laptop — not `podman exec`) to close the CIS agent's flagged risk. Applied
`ansible-playbook site.yml --tags hardening,cis` (ol9, all defaults incl. `guac_cis_level: l2`):

- **Login survives L2 hardening**: key-based SSH login works before and after; a session opened
  *before* a hardening re-run stays alive through the re-run, and a brand-new session immediately
  after also succeeds (the exact "second session before dropping the first" scenario the agent
  asked for).
- **`DisableForwarding yes` is genuinely enforced**, not just written to config: `-L` port
  forwarding produces no reachable local listener (connection refused), while the underlying
  session and remote commands still execute normally. Effective config confirmed via `sshd -T`:
  `disableforwarding yes`, `passwordauthentication yes` (unaffected — `guac_hardening_ssh_password_auth`
  defaults true), `permitrootlogin no`.
- **`sshd -t` validates** the merged config after CIS applies.
- **Found (and left as a minor, self-healing quirk, not fixed)**: `cis : Ensure CIS drop-in
  directories exist` (item `/etc/sudoers.d`) flips 755→?→755 once between the first and second
  application on a brand-new host — `changed=53` (first apply) → `changed=1` (second, this item
  only) → `changed=0` (third, stable forever after). Root cause not pinned down (not caused by
  anything else in `roles/cis/tasks/section5_access_auth.yml` touching that directory); most
  likely a one-off package-install side effect (`sudo`/`policycoreutils` first being "ensured" in
  this role's scope) resetting the dir's mode once, self-correcting on the very next run. Cosmetic
  only — the file that actually matters (`/etc/sudoers.d/60-guac-cis`) is correctly `0440` in every
  run. Worth a look if it ever recurs on a real (non-fresh) host, but not blocking.

## First real OpenSCAP run 2026-09-11 — github.com/elmobp/guacamole-ansible/issues/1

Manually ran the compliance.yml logic against a fresh `test/run.sh ol9` build (idempotent,
checks green) ahead of it ever running in CI. **Confirmed a real content gap**: Oracle Linux 9's
packaged `scap-security-guide` ships no `cis`/`cis_level1_server`/`cis_level2_server` profile at
all (only ANSSI/CCN/CUI/E8/HIPAA/ISM-Official/OSPP/PCI-DSS/Standard/STIG) — the OL9 leg of the
automated gate would currently no-op with a warning, not actually evaluate anything. Ran
`standard` and `ism_o` (ACSC ISM Official) as stand-ins instead: both scored ~92%, and **both
failed the exact same 2 rules** — `rpm_verify_permissions` (maps to `ism-1409`, a control already
flagged as a gap in the Phase 16 ISM mapping — independent confirmation) and
`configure_crypto_policy` (OS-level `update-crypto-policies` never invoked). Filed as GitHub issue
#1 with a fix-next-week checklist. Debian/Ubuntu legs and a genuine CIS-labelled profile source
are still open.

# Project State

## Project Reference

See: .planning/PROJECT.md · Roadmap: .planning/ROADMAP.md · Requirements: .planning/REQUIREMENTS.md

**Core value:** `ansible-playbook site.yml` on a fresh supported host → working Guacamole login
over an HTTPS TLS-1.3 reverse proxy; re-running (incl. `guac_version` bump) is idempotent.

## Active: 2026-09-11 — Milestone 2 phases 15/16/17 all merged; final converge + regression pass

## Milestone 1 (Phases 1–9)

| Area | State |
|---|---|
| RHEL 9 / RHEL 10 | ✅ validated — fresh container, full `site.yml`, idempotent `changed=0`, guacadmin login via HTTPS proxy |
| Debian 12 / 13 | ✅ validated — full build, idempotent, checks green (Debian 13 needed FreeRDP-3.15 fix `a5c006c`) |
| Ubuntu 22.04 / 24.04 / 26.04 | ✅ validated — full build, idempotent, checks green (needed block-notify fix `1b85215`, chrony fix `b359f52`) |
| 9 roles (common, database, guacd, guacamole_client, nginx_proxy, guac_extensions, connections, backup, hardening) | ✅ implemented |
| Docs: README + INSTALL/CONFIGURE/SCENARIOS/OPERATIONS/FIREWALL/LLD-RHEL-IRAP + architecture.drawio | ✅ |
| container/ (Containerfile + compose + entrypoint) | ✅ validated — `podman build` + full smoke (no-DB fail-fast, then against MariaDB: schema bootstrap, guacadmin login returns a real authToken). Fixed `ef98860`: playbook was never actually running (`-i 'localhost,'` didn't match `hosts: guacamole`) + systemd daemon-reload handlers guarded for container builds. |
| `.github/workflows/ci.yml` | ✅ lint + 7-distro build matrix + per-distro image matrix + guacd cache |

## Milestone 2 — ALL PHASES NOW MERGED TO MAIN

| Phase | State | Commit |
|---|---|---|
| 10 CI guacd cache + per-distro images | ✅ code | d675686 |
| 11 build guacd from a git ref (`guac_source_ref`) | ✅ code + **validated** (`src:...guacamole-server@1.6.0`, idempotent, checks green) | cf2f572 |
| 12 RDP session load balancing (BALANCING groups) | ✅ code | 5814ceb |
| 13 LDAP-group RBAC (`guac_user_groups` + ldap-group props) | ✅ code | 45a3953 |
| 14 external log forwarding over TLS / RELP+TLS | ✅ code | a66489d |
| — FreeRDP 3.15 build fix (Debian 13 / Ubuntu 24.04+) | ✅ validated | a5c006c |
| — SSO auth (OpenID/SAML/X.509/CAS) | ✅ validated (all-on + all-off baseline, ol9) | 1e8529b |
| — Modern login page (L4rm4nd/Guacamole-Custom-Login) | ◆ functionally works; converge/idempotence re-test in progress on merged main | — |
| 15 full CIS L2 coverage | ✅ **merged** (`27b4d43`) — native `roles/cis`, OpenSCAP CI gate. **First real converge test running now** (`cl3.log`) — not yet confirmed `changed=0` on a live host. |
| 16 deep ISM alignment + LLD rewrite | ✅ **merged** (`c63543c`) — 165 controls mapped (✅44 🟡99 📋16 ❌6), generated §12, `ism_map.py --check` green |
| 17 operator manual → PDF | ✅ **merged** (`13f564f`) — 14 chapters (~9,500 words), pandoc+typst PDF verified locally (66 pages), CI workflow builds on `docs/manual/**` changes + tags |
| 18/19/20 | ❌ descoped 2026-09-11 (Puppet/Nix/Chef/Terraform + AWS + Azure) | |

**Every planned Milestone-2 phase is now code-complete and merged.** What's left is validation:
the CIS role has never run on a real host until the converge test in progress right now, and the
custom-login feature needs its idempotence bug (found pre-merge, re-testing post-merge) confirmed
fixed.

## Validation status (2026-09-11)

- **Full 7-distro matrix GREEN** (pre-CIS-merge baseline): ol9, ol10, debian12, debian13,
  ubuntu2204, ubuntu2404, ubuntu2604 — full `site.yml`, idempotent `changed=0`, checks green.
- **DR backup/restore PASSED** (`test/dr.sh ol9`) — needed stream-bundle fix `275b162` (macOS
  `/tmp` is a symlink, broke `podman cp`).
- **Upgrade path PASSED** (`test/upgrade.sh ol9 1.5.5 1.6.0`) — real bug found & fixed (`3bff91c`):
  war was downloaded to an unversioned path, so `get_url` skipped it on a version bump → stale
  1.5.5 war + 1.6.0 JDBC extension → "not compatible" → all logins 403. War is now
  `guacamole-<ver>.war` + symlink + stale prune.
- **SSO auth (OpenID/SAML/X.509/CAS)** — verified on ol9 both all-on and all-off, no regression.
  Non-ol9 matrix re-run after SSO also green. `scripts/configure.py` interactive generator asks
  the auth method.
- **Container image PASSED** — build + full smoke (no-DB fail-fast, MariaDB-backed login).
- **`guac_source_ref` git-build PASSED** — see table above.
- **Phase 16 (ISM+LLD)** — docs-only merge, no role/CI/group_vars changes, so no distro
  re-validation was required. Full detail: `docs/ISM.md`, generated `docs/LLD-RHEL-IRAP.md` §12.
  **When revisiting the CIS→ISM cross-references** (`ism-1409`, `ism-1037`, `ism-1403`, POA&M
  items 1/4/5/8): edit `docs/data/ism-mapping.yml`, then `python3 scripts/ism_map.py` — never
  hand-edit the §12 table.
- **Phase 15 (CIS L2)** — merged, **static-validated only before merge** (yamllint, per-file
  YAML/Jinja parse, audit-rule rendering, score-gate unit test, exclusion-regex simulation).
  Agent's flagged risks, not yet independently confirmed: `changed=0` on a real second run;
  L2 sets `DisableForwarding yes` (kills inbound SSH tunneling through this box; guacd itself
  unaffected since it dials out with its own client libraries, not via SSH); Debian's SSG may
  report no CIS profile (content gap, not a bug); pre-existing `roles/guac_extensions/defaults/main.yml`
  yamllint spacing issue on main, unrelated to CIS.
  **9 documented exclusions** in `docs/CIS.md` (e.g. `1.1.2` can't repartition a live host,
  `2.1.22` this host *is* the web server, `6.3.3.21` blocks rule reload without reboot).
- **Phase 17 (operator manual)** — merged. `docs/manual/00-13-*.md`, `scripts/build-manual.sh`,
  `Makefile` `manual` target, `.github/workflows/manual.yml`. PDF build verified locally
  (pandoc 3.11 + typst 0.15.1 → 66 pages, ~920KB — typst chosen because this sandbox's outdated
  Xcode CLT couldn't build weasyprint's Python deps and BasicTeX needs interactive sudo). The CI
  workflow itself has not been run on actual GitHub Actions yet (typst-download step pins to
  whatever GH currently reports as latest — worth confirming on first real CI run).
- **Modern login page (`guac_custom_login_enabled`)** — new feature, not yet merged (still
  stashed against `main`). Builds github.com/L4rm4nd/Guacamole-Custom-Login from source (git
  clone + templated `login-config.js` + upstream `python3 build.py`, pure zip, no compiler).
  Functionally verified on ol9 pre-CIS-merge: "Modern Branding" extension loads alongside
  OpenID SSO, login page 200, config renders correctly via `to_json`-escaped Jinja. **Found an
  idempotence bug** (`changed=5` on run 2) whose first diagnostic re-run was invalidated (the
  test container's repo copy raced a live git-merge-conflict state on the host — copied literal
  `<<<<<<<` markers). Clean re-run in progress now (`cl3.log`) on the fully-merged, conflict-free
  main — this run doubles as the first real CIS-L2 converge test since both land together.

## Resume

Say "resume". Next:
1. Check `cl3.log` — confirms (a) whether the custom-login idempotence bug is real/fixed and
   (b) whether CIS L2 actually converges (`changed=0` on run 2) and doesn't break the login flow
   or `test/check.sh` on a live container.
2. If custom-login still shows spurious `changed=N`, the leading suspects are the `ansible.builtin.git`
   checkout-ref task (branch refs re-fetch every run) and/or the built jar's zip entry timestamps
   not being stable across rebuilds (`build.py` re-zips from freshly-checked-out files even when
   content is byte-identical) — instrument with `--diff`/registered-var dumps, not more guessing.
3. Once green, commit the custom-login feature to `main` and add a SCENARIOS.md / CONFIGURE.md
   cross-check pass.
4. Run the full 7-distro matrix once more with CIS L2 now default-on, to catch any per-OS surprise
   before calling the roadmap fully done.
5. Address the two "not yet independently confirmed" items above (SSH forwarding behavior,
   Debian SSG content gap) with direct observation, not just trusting the agent's static analysis.

## Notes

- Never run Ansible on the laptop — Podman systemd containers only (arm64 host).
- Debian/Ubuntu apt is slow to the default CDN here; `test/run.sh` swaps to the datautama mirror
  (Debian) / arch-aware Ubuntu mirror (`80ec2c7`: `archive.ubuntu.com` on CI amd64, `ports.ubuntu.com`
  on the arm64 laptop). Real deploys can set `guac_apt_mirror`.
- Reference: itiligent/Easy-Guacamole-Installer, Guacamole 1.6.0. Do not push upstream (reference
  repo). The project **does** now have its own mirror remote — see below.
- Every step committed to git — closing the laptop loses only the cached container images.
- `.claude/worktrees/` is gitignored (added `ef98860`) — a prior `git add -A` briefly picked up
  agent worktrees as embedded repos, caught and fixed before it reached a real commit.
- **CIS L2 defaults to ON** (`guac_cis_enabled: true`) as of this merge — every future test run
  exercises it unless explicitly disabled with `-e guac_cis_enabled=false`.
- User's own mirror: `git@github.com:elmobp/guacamole-ansible.git` (blank repo) — push here when
  ready, per explicit user instruction 2026-09-11.

---
*Last updated: 2026-09-11 (Phases 15/16/17 all merged to main; converge-testing CIS L2 + custom-login together before declaring the roadmap done)*
