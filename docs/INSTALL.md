# Install Guide

This guide assumes **no prior knowledge of Ansible or this repository**. Follow it top to
bottom. You will end up with a working Guacamole jump-host reachable over HTTPS.

There is nothing to compile or "build" yourself — you run one command and Ansible does the rest.

---

## 1. What you need

- **A target machine** (physical, VM, or cloud instance) running a supported OS, reachable over
  SSH, where Guacamole will live:

  | Family | Versions |
  |--------|----------|
  | RHEL / Oracle Linux / Rocky / AlmaLinux | 9 or 10 |
  | Debian | 12 or 13 |
  | Ubuntu | 22.04 LTS or 24.04 LTS |

  Minimum: 2 vCPU, 2 GB RAM, 20 GB disk (add 1 vCPU + 2 GB RAM per ~25 concurrent users).

- **A control machine** to run Ansible from. This can be your laptop, a jump box, or even the
  target machine itself. It needs Linux or macOS (Ansible does not run natively on Windows —
  use WSL there).

- **Network**: TCP 22 (SSH), 80 and 443 open to the target. Ports 80/8080/443 must be free on
  the target (nothing else listening).

- **DNS (recommended)**: an A record pointing a name like `guac.internal.example.com` at the
  target's IP. You can use a bare IP, but browsers will complain more about the certificate.

---

## 2. Install Ansible on the control machine

Pick your control machine's OS:

### macOS

```bash
brew install ansible
```

### Ubuntu / Debian

```bash
sudo apt update
sudo apt install -y ansible git
```

### RHEL / Oracle / Rocky / Alma

```bash
sudo dnf install -y epel-release || sudo dnf install -y oracle-epel-release-el$(rpm -E %rhel)
sudo dnf install -y ansible git
```

### Any Linux/macOS via pip

```bash
python3 -m pip install --user ansible
```

Check it works:

```bash
ansible --version      # any 2.14+ is fine
```

---

## 3. Get this repository

```bash
git clone <the repository URL you were given> ansible-guacamole
cd ansible-guacamole
```

(If you received a zip/tarball instead, unpack it and `cd` into the folder.)

---

## 4. Install the two Ansible add-ons this project uses

```bash
ansible-galaxy collection install -r requirements.yml
```

---

## 5. Tell Ansible where your target machine is

Edit `inventory/hosts.ini`. Replace the contents with your target:

```ini
[guacamole]
guac01 ansible_host=203.0.113.10 ansible_user=ubuntu
```

- `ansible_host` — the target's IP or DNS name.
- `ansible_user` — an SSH user on the target that can use `sudo` (on many clouds this is
  `ubuntu`, `ec2-user`, `cloud-user`, `almalinux`, `rocky`, `opc`, ...).
- If you use an SSH key that is not your default, add `ansible_ssh_private_key_file=~/path/key.pem`.

Test connectivity:

```bash
ansible guacamole -m ping
```

You should see `SUCCESS` and `"ping": "pong"`.

> **Running Guacamole on the same machine as Ansible?** Use this inventory instead:
> ```ini
> [guacamole]
> localhost ansible_connection=local
> ```

---

## 6. Set your passwords and site name

### Option A — guided (recommended)

Run the question-and-answer helper. It asks for the hostname, database location, **which
sign-in method** you want (database password, LDAP/AD, OpenID Connect, SAML, or smart-card),
whether to add MFA, and a few extras — then writes a `host_vars/<hostname>.yml` for you.
It installs nothing and can be re-run any time.

```bash
python3 scripts/configure.py
```

Then add that hostname to `inventory/hosts.ini` under `[guacamole]` and skip to step 7.

### Option B — by hand

Open **`group_vars/all.yml`** and change at least these three values:

```yaml
guac_proxy_site: "guac.internal.example.com"    # the DNS name browsers will use
guac_db_password: "<a long random password>"
guac_mysql_root_password: "<another long random password>"
```

Everything else has a sensible default. The full meaning of every option is in
**[CONFIGURE.md](CONFIGURE.md)** — including the single sign-on methods (OpenID Connect, SAML,
X.509 client certificate, CAS) — and ready-to-paste examples for common setups (separate
database server, enabling TOTP/MFA, adding your RDP/SSH target servers, production Let's Encrypt,
FIPS, ...) are in **[SCENARIOS.md](SCENARIOS.md)**.

> **Protect your passwords.** For anything beyond a lab, put the secret values in an
> [Ansible Vault](https://docs.ansible.com/ansible/latest/vault_guide/index.html) file instead of
> plain text:
> ```bash
> ansible-vault create group_vars/vault.yml      # add guac_db_password: "..." etc. here
> ```
> and run playbooks with `--ask-vault-pass`.

---

## 7. Run it

```bash
ansible-playbook site.yml
```

This takes roughly 5–15 minutes the first time (it compiles the Guacamole server from source).
When it finishes you will see:

```
Guacamole build complete.
Proxy:   https://guac.internal.example.com/
Login:   guacadmin / guacadmin  (change immediately)
```

---

## 8. First login

1. Browse to `https://<guac_proxy_site>/`.
2. Accept the self-signed certificate warning (production installs use a real certificate — see
   SCENARIOS.md).
3. Log in as **`guacadmin` / `guacadmin`**.
4. **Immediately** go to *Settings → Preferences* and change the password (or *Settings → Users*
   to create your own admin account and delete `guacadmin`).

---

## 9. Making changes later

Edit `group_vars/all.yml` (or `host_vars/<host>.yml`) and re-run:

```bash
ansible-playbook site.yml
```

Re-running is safe and fast — Ansible only changes what needs changing. This is also how you
**upgrade** (change `guac_version`) and how you **add backend servers, users, or MFA** later.
See [OPERATIONS.md](OPERATIONS.md).
