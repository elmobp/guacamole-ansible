# 11. Container Image

The appliance image is built by running the **same Ansible roles** used for a bare-metal/VM host,
with a few things skipped that only make sense on a persistent OS (systemd service management,
firewall, SELinux). It is not a separately-maintained Dockerfile reimplementation — the roles are
the single source of truth for both delivery forms.

## 11.1 Building and running

```bash
podman build -t guacamole-appliance:local -f container/Containerfile .
podman-compose -f container/docker-compose.yml up -d      # or: docker compose ... up -d
```

Then browse `http://localhost:8080/guacamole/` and log in `guacadmin` / `guacadmin` (change it
immediately, same as any other install).

`container/Containerfile` accepts `BASE_IMAGE` as a build arg (default `oraclelinux:9`) to build
the image against a different supported OS.

## 11.2 How the image is built

`container/Containerfile`'s build stage installs Ansible, then runs:

```bash
ansible-playbook -i inventory/hosts.ini -c local site.yml \
  -e guac_container_build=true \
  -e guac_install_mariadb=false \
  -e guac_install_nginx=false \
  -e guac_db_bootstrap=false \
  -e guac_manage_firewall=false \
  -e guac_manage_selinux=false \
  -e guac_hardening_enabled=false \
  -e guac_backup_enabled=false
```

`guac_container_build=true` is the flag every role checks to skip anything meaningless inside a
container build: no `systemctl enable`/`start` (there's no systemd; the entrypoint owns process
supervision instead), no firewall or SELinux changes, and the final smoke-test post-tasks in
`site.yml` are skipped too (there's no live guacd/Tomcat yet at build time — verification happens
at container start instead, via the `HEALTHCHECK`). MariaDB, nginx, schema bootstrap, hardening,
and the backup timer are all disabled for the *image* build specifically — in `docker-compose.yml`
MariaDB runs as its own separate container, and in a from-scratch `podman run` you're expected to
point at whatever database you're providing.

After the playbook run, the build stage stages the raw schema SQL for first-run bootstrap
(`/opt/guac-schema/schema.sql`, concatenated from the JDBC extension's `mysql/schema/*.sql`), then
strips the build toolchain, Ansible itself, and all source/build artifacts to keep the final image
slim.

## 11.3 Runtime — `entrypoint.sh`

`container/entrypoint.sh` is the container's PID 1. On every start it:

1. Waits for the configured database to accept connections.
2. **First run only** (detected by the absence of the `guacamole_user` table): imports the staged
   schema using the admin credentials, if provided.
3. Renders `/etc/guacamole/guacamole.properties` from environment variables (this happens on
   *every* start, so DB connection details always reflect the current environment even across a
   container recreate with different env vars).
4. Starts `guacd` in the background, then execs Tomcat (`catalina.sh run`) as the foreground
   process — so `podman stop`/`SIGTERM` reaches Tomcat directly and the trap also stops `guacd`.

## 11.4 Environment variables

| Variable | Required | Meaning |
|---|---|---|
| `GUAC_DB_HOST` | **yes** | Database hostname/IP. The entrypoint exits immediately with a clear error if this is unset. |
| `GUAC_DB_PASSWORD` | **yes** | Password for `GUAC_DB_USER`. |
| `GUAC_DB_PORT` | no (default `3306`) | Database port. |
| `GUAC_DB_NAME` | no (default `guacamole_db`) | Database name. |
| `GUAC_DB_USER` | no (default `guacamole_user`) | Database user Guacamole connects as day-to-day. |
| `GUAC_DB_ADMIN_USER` / `GUAC_DB_ADMIN_PASSWORD` | only for first-run schema import | Higher-privileged credentials used **once** to load the schema into an empty database. Not needed on subsequent starts, and not needed at all if the schema is already loaded (e.g. a DBA pre-loaded it, or this is a restart of an already-bootstrapped container). |
| `GUACD_BIND_HOST` / `GUACD_BIND_PORT` | no (default `127.0.0.1` / `4822`) | Where guacd listens inside the container. |
| `GUACAMOLE_HOME` | no (default `/etc/guacamole`) | Set as an image `ENV`; only override if you've bind-mounted a different path. |
| `CATALINA_HOME` | no (default `/opt/tomcat`) | Same — image default, rarely overridden. |

`docker-compose.yml` wires most of these to compose-level variables with the same
`ChangeMe_*_2026` placeholder defaults used elsewhere in this project — **override every
`ChangeMe_*` value before using the compose file for anything beyond a local smoke test.**

## 11.5 How it differs from a bare-metal/VM install

| Aspect | Bare metal / VM (`site.yml` directly) | Container image |
|---|---|---|
| Process supervision | systemd (`guacd`, `tomcat`, `nginx`, `mariadb` units) | `entrypoint.sh` runs `guacd` + Tomcat as PID 1's children; no systemd inside the image |
| Reverse proxy | nginx with TLS by default | Not included in the image — Tomcat's `:8080` is exposed directly. Put a container-platform-level ingress/load balancer with TLS in front for anything beyond local testing. |
| Database | Local MariaDB by default, or a separate server | Always external to the appliance container — either the `db` service in `docker-compose.yml` or a database you supply |
| Firewall / SELinux | Managed by the `common` role | Skipped entirely (`guac_manage_firewall=false`, `guac_manage_selinux=false`) — the container runtime's own network policy applies instead |
| Hardening role | Applied by default | Skipped in the image build (`guac_hardening_enabled=false`) — most of its controls (sysctl, SSH, auditd, kernel modules) are host-level concerns that don't apply inside a container; TLS-1.3-only posture is a proxy/ingress-layer decision at this deployment style |
| Backup | `guac-backup`/`guac-restore` + a systemd timer | The scripts are included in the image, but the systemd timer is inert (no systemd) — schedule backups from the host (`podman exec <ctr> guac-backup`) or a sidecar cron/Kubernetes CronJob instead |
| Upgrades | Bump `guac_version`, re-run `site.yml` in place | Bump `guac_version`, **rebuild the image** (`podman build`), then replace the running container — there is no in-place upgrade of a running container image |

## 11.6 Health check

The image's `HEALTHCHECK` polls `http://127.0.0.1:8080/guacamole/` every 30s (60s start grace
period, 5 retries) — `podman ps` / `docker ps` reports `healthy`/`unhealthy` directly from this,
useful for orchestrator readiness/liveness wiring.
