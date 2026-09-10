#!/usr/bin/python
# -*- coding: utf-8 -*-
"""Idempotently reconcile Guacamole connection groups, connections and users
via the Guacamole REST API. Pure stdlib (urllib) so no extra deps on the host."""
from __future__ import annotations

import json
import urllib.parse
import urllib.request
import urllib.error

from ansible.module_utils.basic import AnsibleModule

DOCUMENTATION = r"""
module: guacamole_reconcile
short_description: Reconcile Guacamole connection groups / connections / users
options:
  base_url: {description: Guacamole API base, required: true, type: str}
  username: {description: admin username, required: true, type: str}
  password: {description: admin password, required: true, type: str, no_log: true}
  datasource: {description: auth data source, default: mysql, type: str}
  connection_groups: {type: list, elements: dict, default: []}
  connections: {type: list, elements: dict, default: []}
  users: {type: list, elements: dict, default: []}
  prune: {type: bool, default: false}
"""


class Guac:
    def __init__(self, base, ds, token):
        self.base = base.rstrip("/")
        self.ds = ds
        self.token = token

    def _url(self, path, params=None):
        q = dict(params or {})
        q["token"] = self.token
        return "%s%s?%s" % (self.base, path, urllib.parse.urlencode(q))

    def req(self, method, path, params=None, body=None):
        data = None
        headers = {"Accept": "application/json"}
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        r = urllib.request.Request(self._url(path, params), data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(r, timeout=30) as resp:
                raw = resp.read().decode()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            raise RuntimeError("%s %s -> %s: %s" % (method, path, e.code, e.read().decode()[:300]))

    # --- groups -------------------------------------------------------
    def group_tree(self):
        t = self.req("GET", "/session/data/%s/connectionGroups/ROOT/tree" % self.ds)
        t.setdefault("identifier", "ROOT")
        return t

    @staticmethod
    def _group_attrs(grp):
        return {
            "max-connections": str(grp.get("max_connections", "")),
            "max-connections-per-user": str(grp.get("max_connections_per_user", "")),
            "enable-session-affinity": "true" if grp.get("session_affinity") else "",
        }

    def create_group(self, parent_id, grp):
        return self.req("POST", "/session/data/%s/connectionGroups" % self.ds, body={
            "parentIdentifier": parent_id, "name": grp["name"],
            "type": grp.get("type", "ORGANIZATIONAL"), "attributes": self._group_attrs(grp)})

    def update_group(self, gid, parent_id, grp):
        self.req("PUT", "/session/data/%s/connectionGroups/%s" % (self.ds, gid), body={
            "identifier": gid, "parentIdentifier": parent_id, "name": grp["name"],
            "type": grp.get("type", "ORGANIZATIONAL"), "attributes": self._group_attrs(grp)})

    # --- connections ------------------------------------------------
    def connections(self):
        return self.req("GET", "/session/data/%s/connections" % self.ds)

    def connection_params(self, cid):
        return self.req("GET", "/session/data/%s/connections/%s/parameters" % (self.ds, cid))

    def create_connection(self, parent_id, name, protocol, params, attrs):
        return self.req("POST", "/session/data/%s/connections" % self.ds, body={
            "parentIdentifier": parent_id, "name": name, "protocol": protocol,
            "parameters": params, "attributes": attrs})

    def update_connection(self, cid, parent_id, name, protocol, params, attrs):
        self.req("PUT", "/session/data/%s/connections/%s" % (self.ds, cid), body={
            "identifier": cid, "parentIdentifier": parent_id, "name": name,
            "protocol": protocol, "parameters": params, "attributes": attrs})

    def delete_connection(self, cid):
        self.req("DELETE", "/session/data/%s/connections/%s" % (self.ds, cid))

    # --- users ----------------------------------------------------
    def users(self):
        return self.req("GET", "/session/data/%s/users" % self.ds)

    def create_user(self, username, password, attrs):
        return self.req("POST", "/session/data/%s/users" % self.ds, body={
            "username": username, "password": password, "attributes": attrs})

    def set_password(self, username, password):
        self.req("PUT", "/session/data/%s/users/%s/password" % (self.ds, username),
                 body={"newPassword": password})

    def user_permissions(self, username):
        return self.req("GET", "/session/data/%s/users/%s/permissions" % (self.ds, username))

    def patch_permissions(self, username, patch):
        self.req("PATCH", "/session/data/%s/users/%s/permissions" % (self.ds, username), body=patch)

    def delete_user(self, username):
        self.req("DELETE", "/session/data/%s/users/%s" % (self.ds, username))


def flatten_groups(node, parent_name="ROOT", out=None):
    out = out if out is not None else {}
    for g in node.get("childConnectionGroups", []) or []:
        out[g["name"]] = {"id": g["identifier"], "parent": parent_name,
                          "type": g.get("type", "ORGANIZATIONAL")}
        flatten_groups(g, g["name"], out)
    return out


def flatten_connections(node, parent_name="ROOT", out=None):
    out = out if out is not None else {}
    for c in node.get("childConnections", []) or []:
        out[c["name"]] = {"id": c["identifier"], "parent": parent_name,
                          "protocol": c.get("protocol")}
    for g in node.get("childConnectionGroups", []) or []:
        flatten_connections(g, g["name"], out)
    return out


def authenticate(base, username, password):
    url = "%s/tokens" % base.rstrip("/")
    data = urllib.parse.urlencode({"username": username, "password": password}).encode()
    r = urllib.request.Request(url, data=data, method="POST")
    with urllib.request.urlopen(r, timeout=30) as resp:
        return json.loads(resp.read().decode())["authToken"]


def run(module):
    p = module.params
    changed = False
    actions = []

    token = authenticate(p["base_url"], p["username"], p["password"])
    g = Guac(p["base_url"], p["datasource"], token)

    # ---- connection groups (create parents before children) ----
    tree = g.group_tree()
    existing_groups = flatten_groups(tree)
    name_to_gid = {"ROOT": tree["identifier"]}
    name_to_gid.update({k: v["id"] for k, v in existing_groups.items()})

    desired_groups = list(p["connection_groups"])
    # crude topological pass: repeat until stable
    for _ in range(len(desired_groups) + 1):
        for grp in desired_groups:
            name = grp["name"]
            parent = grp.get("parent", "ROOT")
            gtype = grp.get("type", "ORGANIZATIONAL")
            if parent not in name_to_gid:
                continue
            if name not in name_to_gid:
                if not module.check_mode:
                    res = g.create_group(name_to_gid[parent], grp)
                    name_to_gid[name] = res["identifier"]
                else:
                    name_to_gid[name] = "__pending__"
                changed = True
                actions.append("create %s group %s" % (gtype.lower(), name))
            else:
                cur = existing_groups.get(name)
                if cur and (cur["parent"] != parent or cur["type"] != gtype):
                    if not module.check_mode:
                        g.update_group(name_to_gid[name], name_to_gid[parent], grp)
                    changed = True
                    actions.append("update group %s" % name)

    # ---- connections ----
    conns = flatten_connections(g.group_tree())
    for c in p["connections"]:
        name = c["name"]
        parent = c.get("parent", "ROOT")
        protocol = c["protocol"]
        params = {k: ("" if v is None else str(v)) for k, v in (c.get("parameters") or {}).items()}
        attrs = {k: ("" if v is None else str(v)) for k, v in (c.get("attributes") or {}).items()}
        pid = name_to_gid.get(parent, tree["identifier"])
        if name not in conns:
            if not module.check_mode:
                g.create_connection(pid, name, protocol, params, attrs)
            changed = True
            actions.append("create connection %s" % name)
        else:
            cid = conns[name]["id"]
            cur_params = g.connection_params(cid) if not module.check_mode else {}
            drift = conns[name]["protocol"] != protocol or conns[name]["parent"] != parent
            for k, v in params.items():
                if str(cur_params.get(k, "")) != v:
                    drift = True
                    break
            if drift:
                if not module.check_mode:
                    g.update_connection(cid, pid, name, protocol, params, attrs)
                changed = True
                actions.append("update connection %s" % name)

    if p["prune"]:
        managed = {c["name"] for c in p["connections"]}
        for name, meta in conns.items():
            if name not in managed:
                if not module.check_mode:
                    g.delete_connection(meta["id"])
                changed = True
                actions.append("prune connection %s" % name)

    # ---- users ----
    existing_users = g.users()
    conns_now = flatten_connections(g.group_tree())
    for u in p["users"]:
        un = u["username"]
        attrs = {k: str(v) for k, v in (u.get("attributes") or {}).items()}
        if un not in existing_users:
            if not module.check_mode:
                g.create_user(un, u.get("password", ""), attrs)
            changed = True
            actions.append("create user %s" % un)
        elif u.get("password") and u.get("update_password"):
            if not module.check_mode:
                g.set_password(un, u["password"])
            changed = True
            actions.append("reset password %s" % un)

        # permissions (additive)
        want_sys = set(u.get("system_permissions") or [])
        want_conn = set(u.get("connections") or [])
        want_grp = set(u.get("groups") or [])
        if want_sys or want_conn or want_grp:
            cur = g.user_permissions(un) if un in existing_users and not module.check_mode else {
                "systemPermissions": [], "connectionPermissions": {}, "connectionGroupPermissions": {}}
            patch = []
            for sp in want_sys:
                if sp not in cur.get("systemPermissions", []):
                    patch.append({"op": "add", "path": "/systemPermissions", "value": sp})
            for cn in want_conn:
                cid = conns_now.get(cn, {}).get("id")
                if cid and "READ" not in cur.get("connectionPermissions", {}).get(cid, []):
                    patch.append({"op": "add", "path": "/connectionPermissions/%s" % cid, "value": "READ"})
            for gn in want_grp:
                gid = name_to_gid.get(gn)
                if gid and "READ" not in cur.get("connectionGroupPermissions", {}).get(gid, []):
                    patch.append({"op": "add", "path": "/connectionGroupPermissions/%s" % gid, "value": "READ"})
            if patch:
                if not module.check_mode:
                    g.patch_permissions(un, patch)
                changed = True
                actions.append("grant permissions %s (%d)" % (un, len(patch)))

    if p["prune"]:
        managed_u = {u["username"] for u in p["users"]} | {p["username"]}
        for un in list(existing_users):
            if un not in managed_u:
                if not module.check_mode:
                    g.delete_user(un)
                changed = True
                actions.append("prune user %s" % un)

    module.exit_json(changed=changed, actions=actions)


def main():
    module = AnsibleModule(
        argument_spec=dict(
            base_url=dict(type="str", required=True),
            username=dict(type="str", required=True),
            password=dict(type="str", required=True, no_log=True),
            datasource=dict(type="str", default="mysql"),
            connection_groups=dict(type="list", elements="dict", default=[]),
            connections=dict(type="list", elements="dict", default=[]),
            users=dict(type="list", elements="dict", default=[]),
            prune=dict(type="bool", default=False),
        ),
        supports_check_mode=True,
    )
    try:
        run(module)
    except Exception as e:  # noqa: BLE001
        module.fail_json(msg=str(e))


if __name__ == "__main__":
    main()
