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

---

## Coverage

All 40 v1 requirements mapped. Phases 1-6 sequential (parallelization disabled in config).
