---
title: "Guacamole Jump-Host Operations Manual"
subtitle: "Ansible-native Apache Guacamole deployment"
author: "Platform / Infrastructure Engineering"
date: "2026-09-11"
---

```{=typst}
#pagebreak()
```

## Document purpose

This manual is the single reference for **operating** a Guacamole jump-host built by this
repository's Ansible playbook. It is written for the person who has to keep the system running
day to day — not the person who wrote the automation.

It covers:

- what the system is made of and how a user's mouse click becomes an RDP/SSH/VNC session
- starting, stopping, and checking the health of every service
- adding and removing users, groups, and backend connections
- authentication methods (database, LDAP/AD, MFA, and single sign-on)
- TLS certificate management
- upgrading the software in place
- backup, restore, and disaster recovery
- hardening, compliance posture, and networking
- the container image build
- troubleshooting real, previously-seen failures
- a full reference of every configuration variable, file path, and systemd unit

## Audience and assumed knowledge

This manual assumes **no Ansible knowledge**. You do not need to read or understand any file
under `roles/` to operate this system day to day. Where an operational task requires editing an
Ansible variable and re-running the playbook (for example, adding a user declaratively, or
bumping the software version), that is spelled out as a copy-paste-able step — treat
`ansible-playbook site.yml` as a single command you run, the same way you'd run `apt upgrade` or
click "Apply" in a control panel.

You *are* expected to be comfortable with:

- basic Linux system administration (SSH, `systemctl`, reading logs, editing a YAML/text file)
- the concept of a reverse proxy, a database, and TLS certificates
- your organisation's identity provider (AD, LDAP, or an OIDC/SAML IdP), if you use SSO

## How this manual relates to the rest of the documentation

This repository also ships documentation aimed at the person *building or extending* the
automation. This manual is written to be a superset of the operational parts of those documents,
in plain language, for someone who doesn't know Ansible — it should never contradict them. Where
detail is genuinely deep (every variable's edge case, every IdP-specific screenshot), this manual
points at the source document rather than duplicating it and risking drift:

| Document | What it's for |
|---|---|
| `README.md` | Project summary, quick start |
| `docs/INSTALL.md` | First-time install walkthrough |
| `docs/CONFIGURE.md` | Every Ansible variable, plain English |
| `docs/SCENARIOS.md` | Copy-paste configuration blocks |
| `docs/OPERATIONS.md` | Upgrades, backup/DR, hardening, containers (source material for this manual) |
| `docs/FIREWALL.md` | Every network flow, for firewall change requests |
| `docs/CIS.md` | CIS benchmark hardening detail (produced separately — see Chapter 9) |
| `docs/LLD-RHEL-IRAP.md` / `docs/ISM.md` | Low-level design and Australian ISM control mapping (produced separately — see Chapter 9) |
| `docs/architecture.drawio` | Editable architecture diagram (open in [draw.io](https://app.diagrams.net)) |

## Conventions used in this manual

- Commands are shown as they would be typed on the Guacamole host itself, run as a user with
  `sudo`, unless stated otherwise.
- `{{ guac_proxy_site }}` style text refers to an Ansible variable — see Chapter 13 for its value
  and meaning. In your own environment substitute the real hostname.
- A shaded box like `guac_version: "1.6.0"` is a line to add or change in `group_vars/all.yml`
  (applies to every host) or `host_vars/<hostname>.yml` (applies to one host).
- Dates in this manual are absolute (e.g. "2026-09-11"), never relative ("last week").

## Version

This edition of the manual was written against `guac_version: 1.6.0`, Tomcat `9.0.121`, and the
repository state as of **2026-09-11**. Re-generate it (`make manual`) whenever `docs/manual/`
changes so the shipped PDF never drifts from the source Markdown.
