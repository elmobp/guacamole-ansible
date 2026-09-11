# 4. Connections — RDP, SSH, VNC Targets

Everything a user can connect *to* is declared in `guac_connections` and organised by
`guac_connection_groups`, reconciled by the `connections` role the same way users are
(Chapter 3). Define these in `host_vars/<hostname>.yml`; re-run
`ansible-playbook site.yml` (or `--tags connections` to only touch this part) whenever you
add, change, or remove a target.

## 4.1 Connection groups — folders and pools

```yaml
guac_connection_groups:
  - { name: "Production", parent: "ROOT",       type: "ORGANIZATIONAL" }
  - { name: "Windows",    parent: "Production",  type: "ORGANIZATIONAL" }
  - { name: "Linux",      parent: "Production",  type: "ORGANIZATIONAL" }
```

| Key | Meaning |
|---|---|
| `name` | Group name shown in the UI. |
| `parent` | Parent group name, or `ROOT` for a top-level group. |
| `type` | `ORGANIZATIONAL` — a plain folder for tidying the connection list, purely cosmetic/permission-scoping. `BALANCING` — see §4.2. |

## 4.2 Load-balanced pools (`BALANCING` groups)

A `BALANCING` group is not a folder — it's a single logical target made of several identical
backend connections. Guacamole routes each new session to the **least-loaded member**; users are
granted access to the *group*, never to an individual member.

```yaml
guac_connection_groups:
  - { name: "Prod", parent: "ROOT", type: "ORGANIZATIONAL" }
  - name: "TS-farm"
    parent: "Prod"
    type: "BALANCING"
    session_affinity: true          # pin a user to the same member for the life of their session
    max_connections: "50"           # optional: cap total concurrent sessions across the pool
    max_connections_per_user: "1"   # optional: cap per-user concurrency

guac_connections:
  - { name: "ts01", parent: "TS-farm", protocol: rdp, parameters: { hostname: "10.0.5.11", port: "3389", security: "nla", "ignore-cert": "true" } }
  - { name: "ts02", parent: "TS-farm", protocol: rdp, parameters: { hostname: "10.0.5.12", port: "3389", security: "nla", "ignore-cert": "true" } }
  - { name: "ts03", parent: "TS-farm", protocol: rdp, parameters: { hostname: "10.0.5.13", port: "3389", security: "nla", "ignore-cert": "true" } }
```

```yaml
guac_users:
  - username: "alice"
    password: "{{ vault_alice_pw }}"
    groups: ["TS-farm"]        # grants access to the POOL, not a specific ts0N host
```

- `session_affinity: true` keeps a given user's reconnects landing on the same pool member for
  the duration of their session (useful for stateful RDP sessions with locally-cached profiles);
  without it, Guacamole is free to route each new connection attempt to whichever member is
  currently least loaded.
- Health is inferred from connection success/load, not an explicit health-check probe — a member
  that's down simply fails to accept new sessions; it isn't automatically drained mid-session.
  Removing a bad member from `guac_connections` and re-running takes it out of rotation cleanly.
- Add or remove pool members by editing the `guac_connections` list and re-running — no restart
  of guacd or Tomcat is required, only the reconciliation step runs.

## 4.3 Individual connections

```yaml
guac_connections:
  - name: "dc01 (RDP)"
    parent: "Windows"
    protocol: rdp
    parameters:
      hostname: "10.0.1.10"
      port: "3389"
      security: "nla"
      ignore-cert: "true"
      domain: "CORP"
      enable-drive: "true"
      drive-name: "guac-transfer"
      drive-path: "/var/lib/guacamole/drive/${GUAC_USERNAME}"
      create-drive-path: "true"
    attributes:
      max-connections: "5"
      max-connections-per-user: "1"

  - name: "web01 (SSH)"
    parent: "Linux"
    protocol: ssh
    parameters:
      hostname: "10.0.2.20"
      port: "22"
      username: "deploy"
      private-key: "{{ vault_web01_ssh_key }}"   # prefer key auth over a stored password

  - name: "kiosk (VNC)"
    parent: "Production"
    protocol: vnc
    parameters:
      hostname: "10.0.3.30"
      port: "5900"
      password: "{{ vault_kiosk_vnc_pw }}"
```

| Key | Meaning |
|---|---|
| `name` | Connection name shown in the UI. |
| `parent` | The connection group it lives in (by name), or `ROOT`. |
| `protocol` | `rdp`, `vnc`, `ssh`, `telnet`, or `kubernetes`. |
| `parameters` | Any Guacamole connection parameter for that protocol — `hostname`, `port`, `username`, `password`, `domain`, `security`, `ignore-cert`, `enable-drive`, `recording-path`, etc. The full parameter list is protocol-specific and lives in the upstream Guacamole manual; the values above are the ones used most often in this project. |
| `attributes` | Connection-level limits: `max-connections`, `max-connections-per-user`, `weight` (relative share of traffic in a balancing group), `failover-only` (member only used when all non-failover members are unavailable). |

Common `parameters` you'll reach for:

| Parameter | Protocols | Notes |
|---|---|---|
| `hostname`, `port` | all | The backend target. |
| `username`, `password`, `domain` | rdp, ssh, vnc, telnet | Stored credentials — put secrets through Ansible Vault, never plaintext in a committed file. |
| `security`, `ignore-cert` | rdp | `security: nla` is the modern, recommended negotiation; `ignore-cert: true` accepts a self-signed/unknown RDP server cert (see Chapter 12 for the cert-error failure mode). |
| `private-key`, `passphrase` | ssh | Key-based auth instead of a password. |
| `enable-drive`, `drive-name`, `drive-path`, `create-drive-path` | rdp | File transfer via a virtual drive. `${GUAC_USERNAME}` expands per logged-in user. |
| `recording-path`, `recording-name` | rdp, ssh, vnc | Session recording — requires `guac_histrec_enabled: true` (Chapter 3/9). |

## 4.4 Pruning

`guac_connections_prune: true` deletes any connection or connection group present in the
database but absent from these lists, on every run — see §3.3 for the full discussion (it
governs users, groups, and connections together with a single switch).

## 4.5 Applying changes

```bash
ansible-playbook site.yml               # full run
ansible-playbook site.yml --tags connections   # only reconcile connections/groups/users
```

Both are safe to run repeatedly — the reconciliation module diffs the declared state against the
live Guacamole database and only issues the API calls needed to close the gap. See
`docs/SCENARIOS.md` §7, §12 and `docs/CONFIGURE.md` for further copy-paste examples.
