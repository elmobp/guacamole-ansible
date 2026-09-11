---
gsd_state_version: "1.0"
status: in-progress
stopped_at: Phases 15/16/17 running via background subagents
last_updated: "2026-09-11T09:30:00.000Z"
state_head: ef98860
---

# Project State

## Project Reference

See: .planning/PROJECT.md · Roadmap: .planning/ROADMAP.md · Requirements: .planning/REQUIREMENTS.md

**Core value:** `ansible-playbook site.yml` on a fresh supported host → working Guacamole login
over an HTTPS TLS-1.3 reverse proxy; re-running (incl. `guac_version` bump) is idempotent.

## Active: 2026-09-11 — milestone-1 full-matrix validation (post FreeRDP-3.15 + block-notify fixes)

## Milestone 1 (Phases 1–9)

| Area | State |
|---|---|
| RHEL 9 / RHEL 10 | ✅ validated — fresh container, full `site.yml` (all 9 roles), idempotent `changed=0`, guacadmin login via HTTPS proxy |
| Debian 12 | ✅ validated — full build, idempotent `changed=0`, checks green |
| Debian 13 | ✅ validated — full build, idempotent `changed=0`, checks green; needed FreeRDP-3.15 fix `a5c006c` (`guac_server_configure_cppflags`) |
| Ubuntu 22.04 | ✅ validated — full build, idempotent `changed=0`, checks green; needed block-notify fix `1b85215` |
| Ubuntu 24.04 | ✅ validated — full build, idempotent `changed=0`, checks green (FreeRDP 3.x path) |
| Ubuntu 26.04 | ✅ validated — full build, idempotent `changed=0`, checks green; needed chrony fix `b359f52` |
| 9 roles (common, database, guacd, guacamole_client, nginx_proxy, guac_extensions, connections, backup, hardening) | ✅ implemented |
| Docs: README + INSTALL/CONFIGURE/SCENARIOS/OPERATIONS/FIREWALL/LLD-RHEL-IRAP + architecture.drawio | ✅ |
| container/ (Containerfile + compose + entrypoint) | ✅ validated — `podman build` + full smoke (no-DB fail-fast, then against MariaDB: schema bootstrap, guacadmin login returns a real authToken). Fixed `ef98860`: playbook was never actually running (`-i 'localhost,'` didn't match `hosts: guacamole`) + systemd daemon-reload handlers now guarded for container builds. |
| `.github/workflows/ci.yml` | ✅ lint + 7-distro build matrix + per-distro image matrix + guacd cache |

## Milestone 2

| Phase | State | Commit |
|---|---|---|
| 10 CI guacd cache + per-distro images | ✅ code | d675686 |
| 11 build guacd from a git ref (`guac_source_ref`) | ✅ code | cf2f572 |
| 12 RDP session load balancing (BALANCING groups) | ✅ code | 5814ceb |
| 13 LDAP-group RBAC (`guac_user_groups` + ldap-group props) | ✅ code | 45a3953 |
| 14 external log forwarding over TLS / RELP+TLS | ✅ code | a66489d |
| — FreeRDP 3.15 build fix (Debian 13 / Ubuntu 24.04+) | ✅ validated | a5c006c |
| 15 full CIS L2 coverage | ✅ code — native `roles/cis` + OpenSCAP CI gate, on branch `worktree-agent-a2c4e587033da3c32`. **Static validation only — never run on a host.** See the Phase 15 entry below before merging. |
| 16 deep ISM alignment + LLD rewrite | ◆ in progress (subagent, worktree `agent-ac8beab45135de3fc` / branch `worktree-agent-ac8beab45135de3fc`) |
| 17 operator manual → PDF | ◆ in progress (subagent, fresh worktree, restarted after a stall) |
| 18/19/20 | ❌ descoped 2026-09-11 (Puppet/Nix/Chef/Terraform + AWS + Azure) | |

## Validation status (2026-09-11)

- **Full 7-distro matrix GREEN**: ol9, ol10, debian12, debian13, ubuntu2204, ubuntu2404, ubuntu2604
  — full `site.yml`, idempotent `changed=0`, `check.sh` all green.
- Session fixes: FreeRDP 3.15 build (`a5c006c`), block-notify→task-notify (`1b85215`),
  run.sh failure propagation (`ea1f39b`) + source guard (`aeafb87`), chrony/26.04 idempotence (`b359f52`).
- **`test/dr.sh ol9` PASSED** — backup host A → restore fresh host B → guacadmin login + marker
  connection intact. Needed dr.sh fix `275b162` (stream bundle A→B; macOS `/tmp` is a symlink).
- **`test/upgrade.sh` — real bug found & fixed (`3bff91c`):** war was downloaded to an unversioned
  path, so `get_url` skipped it on a version bump → stale 1.5.5 war + 1.6.0 JDBC extension →
  "not compatible" → all logins 403. War is now `guacamole-<ver>.war` + symlink + stale prune.
  1.5.5→1.6.0 verified live: login OK, idempotent. Clean end-to-end re-run in progress.
- **`test/upgrade.sh ol9 1.5.5 1.6.0` PASSED** — guacd rebuild + war/jar refresh + schema
  upgrade + login + idempotent.
- **SSO auth added** (`1e8529b` / docs `033a2f9`): OpenID Connect, SAML, X.509 client-cert, CAS —
  toggle-driven identity layers over JDBC. Verified on ol9 both ways:
  all-on (4 extensions load, nginx -t ok, login 200, idempotent) AND all-off baseline
  (changed=0, checks green, no SSO jars) — no regression.
  Interactive `scripts/configure.py` writes host_vars and asks the auth method.
- **Non-ol9 matrix re-run after SSO PASSED**: debian12, debian13, ubuntu2204, ubuntu2404, ubuntu2604
  all green (idempotent, checks pass) — SSO additions caused zero regression.
- **`guac_source_ref=1.6.0` (git-tag build) PASSED** — build marker `src:...guacamole-server@1.6.0`,
  idempotent, checks green.
- **Container image PASSED** — see table above.
- **Phase 15 (CIS L2) — CODE COMPLETE, NOT HOST-VALIDATED.** Branch
  `worktree-agent-a2c4e587033da3c32`. Native `roles/cis` (sections 1–7, OS-family split via
  `vars/{RedHat,Debian}.yml`), wired into `site.yml` as its own role step after `hardening`;
  new `.github/workflows/compliance.yml` (`oscap xccdf eval` against the SSG CIS profile,
  report as artifact, fails below a threshold that starts at 80); new `docs/CIS.md`;
  `docs/CONFIGURE.md` + `ROADMAP.md` updated.
  Plan deviation: implemented natively rather than vendoring **ansible-lockdown** — no upstream
  role exists for Debian 13 or Ubuntu 26.04 (2 of our 9 platforms) and the upstream roles are not
  `changed=0`-clean. Rationale in `docs/CIS.md § Why not ansible-lockdown`.
  That session could not run `podman`/`ansible-playbook` (container host was owned by another
  process), so this is yamllint + YAML parse + Jinja2 compile + `bash -n` + read-through only.
  **Before merging, one converge must confirm: (a) `changed=0` on run 2 with
  `guac_cis_enabled: true`, (b) `test/check.sh` green, (c) sshd still accepts a login — check
  from a second session before dropping the first.** Start with ol9, then debian12 + ubuntu2404
  (the three OS families the compliance workflow scans).

**Milestone 1 + Milestone-2 phases 10–14 + container image + source-ref build: ALL VALIDATED.**
Only Phases 15/16/17 remain, currently running via background subagents (see table above). Each
agent checkpoint-commits incrementally in its own worktree; nothing has been merged to `main` yet.
Note: `.claude/worktrees/` is gitignored (added `ef98860`) — a prior `git add -A` briefly picked up
agent worktrees as embedded repos, caught and fixed before it reached a real commit.

## Resume

Say "resume". Next: check on subagents `a3d0483d3b905f87e` (Phase 15), `a8caa1da37c68fbac`
(Phase 16), `afdcf529c1fd31eae` (Phase 17) via ListAgents/SendMessage or task notifications;
once each finishes, review its worktree branch and merge into `main`; then re-run the affected
distros to confirm no regression before considering the whole roadmap done.

## Notes

- Never run Ansible on the laptop — Podman systemd containers only (arm64 host).
- Debian/Ubuntu apt is slow to the default CDN here; `test/run.sh` swaps to the datautama mirror
  (Debian) / ports.ubuntu.com (Ubuntu). Real deploys can set `guac_apt_mirror`.
- Reference: itiligent/Easy-Guacamole-Installer, Guacamole 1.6.0. Do not push upstream.
- Every step committed to git — closing the laptop loses only the cached container images.

---
*Last updated: 2026-09-11 (milestone-1 + phases 10-14 + image + source-ref all validated; 15/16/17 running via subagents)*
