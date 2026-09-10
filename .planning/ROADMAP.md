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
**Goal:** Same playbook runs on Debian 12/13 + Ubuntu 22.04/24.04; RHEL 9/10 unaffected.
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

## Coverage

All 40 v1 requirements mapped. Phases 1-6 sequential (parallelization disabled in config).
