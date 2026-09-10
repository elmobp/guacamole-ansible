# Roadmap: Ansible Guacamole Installer (RHEL edition)

**Created:** 2026-09-10
**Granularity:** coarse
**Mode:** mvp

Phases build a working vertical slice early (Guacamole reachable on :8080), then layer proxy,
extensions, and the two-distro test harness.

---

### Phase 1: Ansible scaffold + RHEL base
**Goal:** A runnable Ansible project that prepares a RHEL 9/10 host (repos, packages, firewalld, SELinux, users).
**Mode:** mvp
**Requirements:** REPO-01, REPO-02, REPO-03, REPO-04, REPO-05, PLAT-01, PLAT-02, PLAT-03, PLAT-04, PLAT-05
**Success Criteria:**
1. `ansible-playbook site.yml` runs clean in an OL9 and OL10 container with only the `common` role
2. EPEL + CRB enabled, base build toolchain present, firewalld active, guacd service account created
3. Second run is idempotent (0 changed)
4. `group_vars/all.yml` documents every knob carried over from the reference scripts

### Phase 2: Database + guacd from source
**Goal:** MariaDB with the Guacamole schema, and guacd compiled + running on 127.0.0.1:4822.
**Mode:** mvp
**Requirements:** DB-01, DB-02, DB-03, DB-04, DB-05, GUACD-01, GUACD-02, GUACD-03, GUACD-04
**Success Criteria:**
1. `systemctl is-active mariadb guacd` → active in both containers
2. Guacamole DB, user, and JDBC schema present; connector/j jar in `/etc/guacamole/lib/`
3. guacd build is skipped on re-run when the pinned version is already installed
4. FreeRDP 2 (EL9) and FreeRDP 3 (EL10) both produce a working guacd binary

### Phase 3: Guacamole web client on Tomcat
**Goal:** Guacamole login page served on `:8080/guacamole`, `guacadmin` logs in via DB auth.
**Mode:** mvp
**Requirements:** CLIENT-01, CLIENT-02, CLIENT-03, CLIENT-04, CLIENT-05
**Success Criteria:**
1. Tomcat active; `curl -s http://localhost:8080/guacamole/` returns the Guacamole HTML
2. `guacamole.properties` + jdbc extension in place; Tomcat sees `GUACAMOLE_HOME=/etc/guacamole`
3. REST token call authenticates `guacadmin/guacadmin`
4. Idempotent re-run

### Phase 4: Nginx reverse proxy + self-signed TLS
**Goal:** `https://<proxy_site>/` serves Guacamole with working websockets; HTTP redirects to HTTPS.
**Mode:** mvp
**Requirements:** PROXY-01, PROXY-02, PROXY-03, PROXY-04, PROXY-05, PROXY-06
**Success Criteria:**
1. `curl -k https://<proxy_site>/` returns the login page; `curl http://<proxy_site>/` → 301
2. RemoteIpValve present in Tomcat `server.xml`; SELinux allows the proxy connection
3. Token auth for `guacadmin` succeeds through the HTTPS proxy
4. Let's Encrypt role exists, is skipped by default, and is documented for production

### Phase 5: Optional extension roles
**Goal:** TOTP, DUO, LDAP, quickconnect, history-recording, branding — each installs via one toggle.
**Mode:** mvp
**Requirements:** EXT-01, EXT-02, EXT-03, EXT-04, EXT-05, EXT-06
**Success Criteria:**
1. With all toggles on, matching jars appear in `/etc/guacamole/extensions/` and Tomcat restarts clean
2. `guacamole.properties` gains the correct stanza per enabled extension
3. With all toggles off (default), none are installed and login still works
4. Idempotent re-run with a representative toggle set

### Phase 6: Two-distro Podman test harness
**Goal:** A repeatable, documented flow that proves the whole playbook on OL9 and OL10.
**Mode:** mvp
**Requirements:** TEST-01, TEST-02, TEST-03, TEST-04
**Success Criteria:**
1. `test/run.sh` (orchestration only — not install logic) spins OL9 + OL10 systemd containers and runs `site.yml`
2. Post-check script: 4 services active, HTTPS login page served, `guacadmin` token auth OK — passes on both
3. Full-playbook second run is green on both distros
4. README documents the flow and the production Let's Encrypt switch

### Phase 7: One-line upgrades
**Goal:** Bump `guac_version`, re-run `site.yml`, get a clean in-place upgrade — nothing else to touch.
**Mode:** mvp
**Requirements:** UPG-01, UPG-02, UPG-03, UPG-04, UPG-05
**Success Criteria:**
1. Install 1.5.5, then set `guac_version: 1.6.0` and re-run → guacd rebuilt, new war/jars, schema upgraded, login still works
2. Stale `guacamole-*-1.5.5.jar` / old war removed
3. Re-run at same version → changed=0
4. Works on OL9 and OL10

### Phase 9: Debian / Ubuntu family support
**Goal:** Same playbook runs on Debian 12/13 + Ubuntu 22.04/24.04/26.04; RHEL 9/10 unaffected.
**Mode:** mvp
**Requirements:** DEB-01, DEB-02, DEB-03, DEB-04, DEB-05
**Success Criteria:**
1. Roles branch by `ansible_os_family` (RedHat vs Debian) via `vars/{{ ansible_os_family }}.yml`
2. `test/run.sh` runs ol9, ol10, debian12, debian13, ubuntu2204, ubuntu2404 — all green (build + idempotence + check.sh)
3. RHEL runs identical to before the refactor
4. README documents the supported matrix

### Phase 8: Container image + compose
**Goal:** Build a Guacamole container image from the roles; compose stack with MariaDB.
**Mode:** mvp
**Requirements:** IMG-01, IMG-02, IMG-03, IMG-04, IMG-05
**Success Criteria:**
1. `podman build` produces an image running guacd + tomcat (+ nginx)
2. `podman-compose up` (or docker compose) brings up Guacamole + MariaDB
3. `guacadmin` can log in against the compose stack
4. README documents the build + run

---

## Milestone 2 — requested 2026-09-10 (sized honestly, sequenced)

**Descoped 2026-09-11:** Phases 18 (Puppet/Nix/Chef/Terraform CDK), 19 (AWS), 20 (Azure). Remaining M2 work: 15 (CIS L2), 16 (ISM+LLD), 17 (PDF manual).

**Phases 10-14 implemented + validated on OL9 (2026-09-11): base PASS, M2 smoke failed=0, idempotent, BALANCING/RBAC/TLS-syslog asserted.**

Pick phases to run; they are mostly independent. Sizes: **S** ≈ hours, **M** ≈ a day, **L** ≈ multi-day, **XL** ≈ a project.

### Phase 10 ✅ CI build cache + per-distro images  **[M]**
- Cache the compiled `guacd` tree (+ war/jar downloads) in GitHub Actions keyed on
  `guac_version` + arch + distro; playbook installs from cache, **skips the compile step** when the
  cached binary matches. Local `guac_build_dir` becomes a restorable cache dir.
- `container/` builds an image **per supported OS** (build-arg `BASE_IMAGE`), matrix in CI, pushed
  to `ghcr.io` (or artifact) on tag.
- **Success:** second CI run for an unchanged `guac_version` does not recompile; 7 images build.

### Phase 11 ✅ Build Guacamole from a source branch  **[M]**
- `guac_source_ref` (tag | branch | commit) + `guac_source_repo` — when set, `git clone` +
  `mvn package` the client and `autoreconf && ./configure && make` the server from that ref
  instead of the release tarball. Version string derived from the ref.
- CI: this path tested **on OL only** (per request); release-tarball path stays the matrix default.
- **Success:** `-e guac_source_ref=1.6.0` builds + logs in on OL9.

### Phase 12 ✅ Backend RDP session load balancing  **[S–M]**
- `connections` module already accepts `type: BALANCING` groups; add: member weighting,
  `enable-session-affinity`, health note, and docs/example. Optional: guacd behind
  multiple backends via balancing group of identical connections.
- **Success:** a balancing group with 3 RDP members round-robins; affinity honoured.

### Phase 13 ✅ RBAC via LDAP groups  **[M]**
- LDAP extension: `ldap-group-base-dn`, `ldap-member-attribute`, group→connection mapping in the
  Guacamole schema; `guac_ldap_rbac` list: `{ group_dn, connections: [...], groups: [...], system: [...] }`
  reconciled by the `connections` module (grant to `USER_GROUP` entities).
- **Success:** members of `CN=guac-web,OU=...` see only the `web` connections; non-members don't.

### Phase 14 ✅ External log forwarding over TLS  **[M]**
- Extend `hardening`: rsyslog **RELP + TLS** (or omfwd + TLS), CA + client cert config
  (`guac_syslog_tls_ca`, `_cert`, `_key`, `guac_syslog_relp`), `audisp` → rsyslog → collector.
  Plain TCP/UDP stays available; TLS is the recommended path.
- **Success:** events arrive at a TLS syslog collector; `openssl s_client` shows TLS 1.3.

### Phase 15: CIS L2 — full coverage  **[L]**
- Adopt the upstream **ansible-lockdown** `RHEL9-CIS` / `UBUNTU24-CIS` roles (vendored or as a
  dependency) run in "L2 server" profile, layered under our app-specific exceptions
  (Tomcat/nginx/guacd must keep working). Partition/mount, AIDE, PAM `pwquality`/`faillock`,
  GRUB password, banner, aide, rsyslog, chrony, auditd immutable, etc.
- Gate: OpenSCAP scan in CI with the SSG CIS profile; publish the score; document accepted
  deviations. `guac_hardening_level: l2` becomes "real CIS L2 with documented exceptions".
- **Success:** OpenSCAP CIS L2 score ≥ [target]; every non-pass has a written justification.

### Phase 16: Deep ISM alignment + LLD refresh  **[L]**
- Work the **current published ISM** systematically for every control family in scope
  (config/patching, IDAM, crypto/TLS, logging/audit, backup, network, web, DB, media, ops);
  for each: implement, mark partial with the gap, or mark customer-responsibility with why.
- Rewrite `docs/LLD-RHEL-IRAP.md` §12 as a control-by-control matrix over the real ISM (not the
  quiz dataset), each row linked to the implementing role/task, with an assessor-ready evidence
  column and a POA&M.
- **Success:** LLD covers every in-scope ISM control with an honest status + evidence pointer.

### Phase 17: Operator manual (PDF)  **[L]**
- `docs/manual/` (Markdown) → PDF via pandoc in CI. Every moving piece: architecture,
  each role & variable, install, day-2 ops, upgrades, backup/restore/DR drills, connection &
  RBAC administration, MFA enrolment, TLS/cert rotation, hardening & FIPS, log/SIEM,
  troubleshooting runbooks, disaster scenarios. Diagrams from `architecture.drawio` (exported PNG).
- **Success:** `make manual` produces `guacamole-operator-manual.pdf`; CI attaches it to releases.

### Phase 18: `iac/` multi-tool implementations  — ❌ DESCOPED 2026-09-11 (out of scope)
- New branch `iac`, subfolders: `ansible/` (move current), then **parallel re-implementations**:
  `puppet/`, `nix/` (NixOS module), `chef/` (cookbook), `terraform-cdk/` (CDKTF Python).
- **Reality check:** this is 4 full re-implementations to build **and keep in sync** with every
  future change. Strong recommendation: keep Ansible as the config-management source of truth and
  pick **one** alternative if there's a real driver (e.g. NixOS module for reproducibility, *or*
  Puppet if that's the site standard). Confirm before starting.
- **Success (per tool chosen):** produces a working, idempotent Guacamole host matching the
  Ansible build; its own CI leg.

### Phase 19: AWS deployment (Python CDK)  — ❌ DESCOPED 2026-09-11 (out of scope)
- `iac/aws-cdk/` (Python): VPC with JSON-driven public/private subnets, ALB (TLS 1.3, ACM cert)
  → private EC2 running the Ansible build via user-data/SSM, RDS MariaDB (private), security
  groups from the FIREWALL.md matrix, Secrets Manager for DB/LDAP/Duo, CloudWatch/S3 for logs +
  backup bundles. All sizing/subnets/toggles from a single `config.json`.
- **Success:** `cdk deploy` → reachable Guacamole; `cdk destroy` leaves nothing. Tested with
  **user-supplied creds**, **cleaned up immediately after**.

### Phase 20: Azure deployment  — ❌ DESCOPED 2026-09-11 (out of scope)
- `iac/azure/` equivalent (Bicep or CDKTF): VNet + subnets from JSON, App Gateway (TLS 1.3) →
  private VM, Azure Database for MariaDB (private), NSGs from FIREWALL.md, Key Vault, Log
  Analytics + storage for logs/backups.
- **Success:** deploy → reachable → destroy clean. Tested with **user-supplied creds**, cleaned
  up immediately.

_Cloud credential handling (descoped):_ creds are only used for a deploy→verify→**destroy** cycle; nothing
persisted; teardown confirmed by `cdk destroy` / `az group delete` + a resource-list check.

---

## Coverage

Milestone 1 (Phases 1-9): implemented; RHEL validated. Milestone 2 (Phases 10-20): planned, sized above.
