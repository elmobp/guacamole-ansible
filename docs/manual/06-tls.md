# 6. TLS Certificates

`guac_tls_mode` picks one of three postures. **All three are TLS 1.3 only**
(`guac_proxy_ssl_protocols: "TLSv1.3"`) — there is no TLS 1.2 fallback anywhere this playbook
terminates or initiates TLS, including the internal guacd link when
`guac_guacd_tls_enabled: true`.

| Mode | When to use it |
|---|---|
| `self-signed` (default) | Lab, internal-only, or behind another TLS-terminating load balancer that already presents a trusted cert to end users. |
| `letsencrypt` | Public-facing production, with a real DNS name and port 80 reachable from the internet. |
| `none` | No TLS at nginx — Tomcat is exposed on `:8080` directly (or nginx proxies plain HTTP). Not recommended; only for a host that's itself behind other TLS termination. |

## 6.1 Self-signed (default)

Generated automatically at `guac_ssl_cert_dir`/`guac_ssl_key_dir`
(`/etc/nginx/ssl/cert`/`/etc/nginx/ssl/private` by default), named after `guac_proxy_site`:

```yaml
guac_cert_rsa_keylength: 3072      # ISM guidance: RSA modulus >= 3072 preferred
guac_cert_days: 3650
guac_cert_country: "AU"
guac_cert_state: "Victoria"
guac_cert_location: "Melbourne"
guac_cert_org: "Itiligent"
guac_cert_ou: "I.T."
```

The certificate's Subject Alternative Names cover `guac_proxy_site`, `guac_server_name`, and the
host's default IPv4 address, so browsers accept it (after the usual self-signed warning) for
either the DNS name or the bare IP.

**Renewal:** the cert is generated once (`creates:` guards the `openssl req` task) with a
`guac_cert_days`-day lifetime — there is no automatic renewal for self-signed certs, because
there's no external authority to renew against. To rotate it before expiry (or after changing
`guac_proxy_site`), delete the two files and re-run:

```bash
sudo rm /etc/nginx/ssl/cert/<old-name>.crt /etc/nginx/ssl/private/<old-name>.key
ansible-playbook site.yml --tags proxy
```

## 6.2 Let's Encrypt

```yaml
guac_tls_mode: letsencrypt
guac_le_dns_name: "guac.example.com"     # public DNS A record -> this host, port 80 reachable
guac_le_email: "it-ops@example.com"
```

The nginx role installs `certbot` and its nginx plugin, then runs
`certbot --nginx --non-interactive --agree-tos -m <email> -d <dns_name> --redirect`. Certbot
edits the nginx vhost itself to add the certificate paths and the HTTP→HTTPS redirect.

**Renewal:** certbot's own OS-installed systemd timer (`certbot-renew.timer` /
`certbot.timer`, depending on distro packaging) handles renewal automatically — this repo does
not add a separate renewal job. Confirm it's active:

```bash
systemctl list-timers | grep -i certbot
sudo certbot renew --dry-run
```

Port 80 must remain reachable from the internet for the HTTP-01 challenge, both at initial
issuance and at every renewal.

## 6.3 Replacing the certificate with one from your own CA

For an internally-issued (enterprise PKI) certificate rather than self-signed or Let's Encrypt,
skip both automated modes and drop your own material in place:

```bash
sudo cp your-cert-chain.crt /etc/nginx/ssl/cert/<guac_proxy_site>.crt
sudo cp your-private.key    /etc/nginx/ssl/private/<guac_proxy_site>.key
sudo chmod 640 /etc/nginx/ssl/private/<guac_proxy_site>.key
sudo nginx -t && sudo systemctl reload nginx
```

Keep `guac_tls_mode: self-signed` so the playbook doesn't try to regenerate or replace the files
on the next run (the `creates:` guard on the self-signed cert task means it won't overwrite an
existing file at that path regardless of how it got there) — but be aware a from-scratch
`guac_proxy_site` change or a fresh host will regenerate a self-signed cert at the same path, so
re-apply your CA-issued material after any change that touches `guac_proxy_site`.

## 6.4 The X.509 client-certificate auth vhost

When `guac_ssl_auth_enabled: true` (Chapter 5.5c), nginx serves a **second** `server {}` block on
443 for `guac_ssl_auth_domain` (and `*.<domain>`), doing `ssl_verify_client optional` against the
CA bundle in `guac_ssl_auth_client_ca`. It reuses the same TLS certificate as the primary vhost by
default (fine for a lab); production deployments should give this vhost its own **wildcard**
certificate for `*.<guac_ssl_auth_domain>`, since the ssl extension bounces the browser through
ephemeral subdomains during the certificate handshake. Follow the same replacement steps as §6.3,
just for the second `server_name`.

## 6.5 Verifying the negotiated protocol

```bash
openssl s_client -connect <guac_proxy_site>:443 -tls1_3 </dev/null 2>&1 | grep -E "Protocol|Cipher"
# A TLS 1.2 (or earlier) attempt should be REJECTED:
openssl s_client -connect <guac_proxy_site>:443 -tls1_2 </dev/null 2>&1 | grep -i "handshake failure\|no protocols"
```

See Chapter 9 for how this fits the broader hardening/compliance posture, and Chapter 12 for
common `nginx -t` failure modes when editing TLS config by hand.
