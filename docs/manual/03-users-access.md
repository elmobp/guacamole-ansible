# 3. Users, Groups, and Access

Guacamole has two ways to manage who can log in and what they can reach: **through the web UI**
(fine for ad-hoc changes and small teams) and **declaratively through Ansible variables** (the
recommended approach once you have more than a handful of users, because it's reviewable,
repeatable, and reruns cleanly). You can mix both, with one caveat around pruning (§3.3).

## 3.1 Managing users and groups through the UI

Log in as an account with the `ADMINISTER` system permission (by default, `guacadmin`) and open
**Settings**:

- **Settings → Users** — create/delete users, set passwords, grant system-wide permissions
  (`ADMINISTER`, `CREATE_CONNECTION`, `CREATE_USER`, ...), and grant per-connection or per-group
  **READ** (use) permission.
- **Settings → Groups** — create Guacamole *user groups* (not to be confused with *connection
  groups*, which organize connections). A user group can be granted permissions once and every
  member inherits them — this is also how LDAP-group RBAC surfaces (§3.4).
- **Settings → Preferences** — a logged-in user's own password/TOTP enrolment.

Changes made in the UI live in the database immediately. They are **not** overwritten by
re-running the playbook, *unless* `guac_connections_prune: true` is set (§3.3) and the object in
question collides with something the playbook manages.

## 3.2 Managing users and groups declaratively

Define everything in `group_vars/all.yml` or, more commonly, `host_vars/<hostname>.yml`, and
re-run `ansible-playbook site.yml`. This is reconciled by the `connections` role, which calls the
Guacamole REST API through a small idempotent module
(`roles/connections/library/guacamole_reconcile.py`) — it diffs what you've declared against
what's actually in the database and only changes what's different.

```yaml
guac_users:
  - username: "alice"
    password: "{{ vault_alice_pw }}"          # used only when the account is first created
    attributes:
      guac-full-name: "Alice Smith"
      guac-email-address: "alice@example.com"
    system_permissions: []                     # e.g. [CREATE_CONNECTION, CREATE_USER, ADMINISTER]
    connections: ["dc01 (RDP)", "web01 (SSH)"]  # grants READ (use) on these connections
    groups: ["Linux"]                           # grants READ (use) on these connection groups

  - username: "bob"
    password: "{{ vault_bob_pw }}"
    update_password: true                       # force-reset bob's password to the value above
    system_permissions: ["CREATE_CONNECTION"]
    groups: ["Production"]
```

Key points:

- `password` is only used when the account doesn't exist yet — re-running the playbook does
  **not** silently reset an existing user's password. Add `update_password: true` on a user entry
  the one time you actually want to force a reset (a locked-out account, a compromised
  credential), then remove that key again so the next run doesn't keep resetting it.
- `connections` / `groups` grant **READ** (use) permission only — enough to open a session, not
  to edit the connection.
- `system_permissions` are account-wide rights, most commonly `CREATE_CONNECTION` (self-service
  connection creation), `CREATE_USER`, and `ADMINISTER` (full admin, same as `guacadmin`).
- Removing a user from `guac_users` does **not** delete them from Guacamole unless
  `guac_connections_prune: true` (§3.3) — leaving it out is a safe way to stop managing an
  account without destroying it.

See `docs/SCENARIOS.md` §8 and `docs/CONFIGURE.md` ("Backend servers, groups and users") for the
full key reference and more examples.

## 3.3 Pruning — making the playbook the single source of truth

```yaml
guac_connections_prune: true
```

When set, every run **deletes** any connection, connection group, or user that exists in the
database but is **not** listed in `guac_connections` / `guac_connection_groups` / `guac_users`.
This is powerful and dangerous:

- Anything created ad-hoc through the UI since the last run is removed on the next
  `ansible-playbook site.yml`.
- It's the right setting if this playbook is genuinely your only change-management path for
  Guacamole objects (e.g. GitOps-style, config reviewed in a pull request).
- Leave it `false` (the default) if administrators are also expected to make changes through the
  UI, or you're not yet confident your `guac_users`/`guac_connections` lists are complete.

`guacadmin` itself, and any user you didn't declare, are candidates for deletion under pruning —
double-check your list includes every account you want to keep before flipping this on.

## 3.4 RBAC with LDAP / SSO groups

Two independent things called "groups" work together here:

1. **`guac_connection_groups`** — a folder (`ORGANIZATIONAL`) or load-balanced pool
   (`BALANCING`) that connections live inside. See Chapter 4.
2. **`guac_user_groups`** — a Guacamole *user group* whose **name matches a group name your
   identity provider hands over** (an LDAP/AD group's CN, or the SSO `groups` claim/attribute).
   Membership of that group is not managed here — LDAP or the IdP owns membership; this playbook
   only declares what *permissions that group carries* inside Guacamole.

```yaml
guac_user_groups:
  - name: "guac-web-admins"          # must match the LDAP/AD group CN (or SSO groups claim value)
    connections: ["dc01 (RDP)"]
    groups: ["Windows"]
    system_permissions: ["CREATE_CONNECTION"]
```

For this to work end-to-end:

- **LDAP-sourced RBAC** needs `guac_ldap_enabled: true` and, in `guac_ldap`, `group_base_dn`,
  `member_attribute`, `member_attribute_type` (`dn` or `uid`), and `group_name_attribute`
  (default `cn`) — see `docs/CONFIGURE.md`. When a user authenticates via LDAP (or via the
  database with LDAP supplying group lookups), Guacamole resolves their LDAP group memberships
  and matches them against `guac_user_groups` by name.
- **SSO-sourced RBAC** (OpenID Connect / SAML) reads the identity provider's group claim/attribute
  (`groups_claim_type` for OIDC, `group_attribute` for SAML — both default `groups`) and matches
  it the same way.

A user who is a member of `CN=guac-web-admins,OU=...` in AD, or whose OIDC token carries
`"groups": ["guac-web-admins"]`, inherits exactly the connections/groups/permissions declared for
`guac-web-admins` above — on their **next** login, with no per-user entry needed in
`guac_users`. This scales far better than declaring every user by hand once your organisation
already manages group membership in the directory.

## 3.5 Resetting the `guacadmin` password

The JDBC schema always creates the account `guacadmin` / `guacadmin`
(`guac_default_admin_user` / `guac_default_admin_password`) — the playbook's own smoke test and
the `connections` role's reconciliation both authenticate as this account, so **do not delete or
lock it out of the API without updating the variable to match**, or the next `site.yml` run will
fail its final smoke test and the reconciliation step.

**Recommended production practice**, in order:

1. Log in once as `guacadmin` / `guacadmin`.
2. **Settings → Users → guacadmin → Preferences** (or create a brand-new personal admin account
   with `ADMINISTER`, and delete `guacadmin` instead — either is fine).
3. If you change `guacadmin`'s password directly rather than replacing it, **also update**
   `guac_default_admin_password` in your vault to the new value, so future playbook runs
   (upgrades, connection reconciliation, the final smoke test) keep authenticating correctly.
4. If you replace `guacadmin` with your own admin account instead, keep `guac_default_admin_user`
   / `guac_default_admin_password` pointing at *some* account that still has `ADMINISTER` and a
   known password — the playbook needs one to talk to the API. A dedicated, vaulted
   service-account credential (not a human's daily login) is the cleanest choice here.

**Forgotten/locked-out password recovery** (no working admin account left): declare a fresh
admin in `guac_users` with `system_permissions: ["ADMINISTER"]` and a known password, and
re-run — but this itself needs an *existing* working credential in `guac_default_admin_user`/
`guac_default_admin_password` to authenticate the reconciliation call. If that's also lost, the
only path back is a direct database fix (see the upstream Guacamole documentation for
recalculating a `guacamole_user_password_history`/`guacamole_entity` row's salted hash) — treat
this as a last resort and restore from backup (Chapter 8) if you have one instead.
