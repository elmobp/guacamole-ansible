---
gsd_state_version: "1.0"
status: in-progress
stopped_at: integrating Phase 15/16 into main; Phase 17 running; custom-login feature in progress
last_updated: "2026-09-11T10:00:00.000Z"
state_head: b84b45f
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
| — SSO auth (OpenID/SAML/X.509/CAS) | ✅ validated | 1e8529b |
| — Modern login page (L4rm4nd/Guacamole-Custom-Login) | ◆ in progress (idempotence bug under investigation) | — |
| 15 full CIS L2 coverage | ✅ code-complete on `worktree-agent-a2c4e587033da3c32` — **not yet merged to main, not yet converge-tested** |
| 16 deep ISM alignment + LLD rewrite | ✅ **merged to main** — 165 controls mapped (✅44 🟡99 📋16 ❌6), generated §12 + §12.1 exclusions + 19-item POA&M, `scripts/ism_map.py --check` green |
| 17 operator manual → PDF | ◆ in progress (subagent, fresh worktree, restarted after an earlier stall) |
| 18/19/20 | ❌ descoped 2026-09-11 (Puppet/Nix/Chef/Terraform + AWS + Azure) | |

## Validation status (2026-09-11)

- **Full 7-distro matrix GREEN**: ol9, ol10, debian12, debian13, ubuntu2204, ubuntu2404, ubuntu2604
  — full `site.yml`, idempotent `changed=0`, `check.sh` all green.
- Session fixes: FreeRDP 3.15 build (`a5c006c`), block-notify→task-notify (`1b85215`),
  run.sh failure propagation (`ea1f39b`) + source guard (`aeafb87`), chrony/26.04 idempotence (`b359f52`).
- **`test/dr.sh ol9` PASSED** — backup host A → restore fresh host B → guacadmin login + marker
  connection intact. Needed dr.sh fix `275b162` (stream bundle A→B; macOS `/tmp` is a symlink).
- **`test/upgrade.sh ol9 1.5.5 1.6.0` PASSED** — real bug found & fixed (`3bff91c`): war was
  downloaded to an unversioned path, so `get_url` skipped it on a version bump → stale 1.5.5 war +
  1.6.0 JDBC extension → "not compatible" → all logins 403. War is now `guacamole-<ver>.war` +
  symlink + stale prune. Verified: guacd rebuild + war/jar refresh + schema upgrade + login +
  idempotent.
- **SSO auth added** (`1e8529b` / docs `033a2f9`): OpenID Connect, SAML, X.509 client-cert, CAS —
  toggle-driven identity layers over JDBC. Verified on ol9 both ways: all-on (4 extensions load,
  nginx -t ok, login 200, idempotent) AND all-off baseline (changed=0, checks green, no SSO jars).
- **Non-ol9 matrix re-run after SSO PASSED**: debian12, debian13, ubuntu2204, ubuntu2404, ubuntu2604
  all green (idempotent, checks pass) — SSO additions caused zero regression.
- **`guac_source_ref=1.6.0` (git-tag build) PASSED** — build marker `src:...guacamole-server@1.6.0`,
  idempotent, checks green.
- **Container image PASSED** — see table above.
- **Phase 16 (ISM + LLD) COMPLETE and merged** — docs-only, no role/CI/group_vars changes, so no
  re-validation of the distro matrix was required. `docs/LLD-RHEL-IRAP.md` §12 is now **generated**
  from `docs/data/ism-mapping.yml` + a hash-pinned control dataset by `scripts/ism_map.py` (stdlib
  only). 165 controls mapped — every row citing a variable, file, unit directive or verified
  behaviour. Plus §12.1 (25 out-of-scope families) and §12.2 (19-item POA&M seed). Methodology and
  refresh procedure in `docs/ISM.md`.
  - Verification: `ism_map.py --check` exits 0 (table matches the generator byte-for-byte); all 21
    LLD anchors resolve and none are unused; all `guac_*` variables cited across the mapping and
    LLD exist in the repo; 20+ rows spot-checked line-by-line against the roles; dataset
    re-downloaded and SHA-256 re-verified unchanged.
  - **Known caveat:** the dataset is a third-party community extract of the ISM with no release
    label, not the ACSC publication (cyber.gov.au was unreachable non-interactively). Stated in
    `docs/ISM.md` §1, the §12 disclaimer and the sidecar. Swapping in the official XLSX/OSCAL
    release is a data change only.
  - **When Phase 15 lands**, revisit the §12 rows that name `roles/cis` (`ism-1409`, `ism-1037`,
    `ism-1403`) and POA&M items 1, 4, 5 and 8 — several 🟡/❌ statuses should improve. Edit
    `docs/data/ism-mapping.yml`, then `python3 scripts/ism_map.py`; never hand-edit the §12 rows.
- **Phase 15 (CIS L2) CODE-COMPLETE, not yet merged**: full `roles/cis/` (6 CIS section task files
  + defaults + OS-family vars + handlers + 11 templates), wired into `site.yml` as its own step
  after `hardening` (`guac_cis_enabled`, default true), `.github/workflows/compliance.yml`
  (OpenSCAP CIS gate, ratchets from an 80% threshold), `docs/CIS.md`, 9 justified exclusions.
  Static-validated only (yamllint, per-file YAML/Jinja parse, audit-rule rendering, score-gate
  unit test, exclusion-regex simulation) — **no podman/ansible-playbook run yet**. Agent's own
  flagged risks before trusting it: confirm `changed=0` on a real second run; **verify SSH access
  from a second session before dropping the first** (L2 sets `DisableForwarding yes`, which kills
  inbound SSH tunneling through this box — guacd itself is unaffected); Debian's SSG may report no
  CIS profile (content gap, not a bug); pre-existing `roles/guac_extensions/defaults/main.yml`
  yamllint spacing issue on main, unrelated to this phase.
- **Modern login page in progress**: `guac_custom_login_enabled` builds
  [L4rm4nd/Guacamole-Custom-Login](https://github.com/L4rm4nd/Guacamole-Custom-Login) from source
  (git clone + templated `login-config.js` + upstream `python3 build.py`, pure zip, no compiler).
  Functionally verified on ol9 (with `guac_openid_enabled` too): "Modern Branding" extension
  loads, login page 200, config renders correctly. **Idempotence bug found**: second run shows
  `changed=5` instead of 0 — root cause not yet confirmed (suspect the `git` module's checkout-ref
  handling and/or the built jar's zip timestamps not being stable across rebuilds). Diagnostic
  re-run in progress (`cl2.log`). Not yet committed to `main` (stashed).

**Milestone 1 + Milestone-2 phases 10–14 + container image + source-ref build + Phase 16: ALL
VALIDATED/MERGED.** Remaining: merge Phase 15 (needs a real converge test first), finish Phase 17,
close out the custom-login idempotence bug.

## Resume

Say "resume". Next:
1. Diagnose and fix the custom-login idempotence bug (`changed=5` on run 2) — check `cl2.log`.
2. Merge `worktree-agent-a2c4e587033da3c32` (Phase 15) into `main`, then **actually converge-test
   it** (ol9 first; verify SSH from a second session before dropping the first) before trusting
   `changed=0`.
3. Check on Phase 17 (`afdcf529c1fd31eae`) via task notification or ListAgents/SendMessage; merge
   its worktree when done.
4. After Phase 15 lands, revisit the ISM §12 rows/POA&M items noted above via `ism_map.py`.
5. Final full-matrix regression once everything is merged.

## Notes

- Never run Ansible on the laptop — Podman systemd containers only (arm64 host).
- Debian/Ubuntu apt is slow to the default CDN here; `test/run.sh` swaps to the datautama mirror
  (Debian) / ports.ubuntu.com (Ubuntu, arch-aware since `80ec2c7`). Real deploys can set `guac_apt_mirror`.
- Reference: itiligent/Easy-Guacamole-Installer, Guacamole 1.6.0. Do not push upstream.
- Every step committed to git — closing the laptop loses only the cached container images.
- `.claude/worktrees/` is gitignored (added `ef98860`) — a prior `git add -A` briefly picked up
  agent worktrees as embedded repos, caught and fixed before it reached a real commit.

---
*Last updated: 2026-09-11 (Phase 16 merged; Phase 15 code-complete pending merge+test; Phase 17 + custom-login in progress)*
