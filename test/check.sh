#!/usr/bin/env bash
# Post-install functional verification. Run inside the target host/container.
set -uo pipefail
fail=0
ok()   { echo "  PASS  $1"; }
bad()  { echo "  FAIL  $1"; fail=1; }

echo "== services =="
for svc in mariadb guacd tomcat nginx; do
  if systemctl is-active --quiet "$svc"; then ok "$svc active"; else bad "$svc not active"; fi
done

echo "== guacd socket =="
if (exec 3<>/dev/tcp/127.0.0.1/4822) 2>/dev/null; then ok "guacd listening on 127.0.0.1:4822"; else bad "guacd port 4822 closed"; fi

echo "== direct web app =="
code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/guacamole/ || true)
[[ "$code" == "200" ]] && ok "tomcat /guacamole/ -> 200" || bad "tomcat /guacamole/ -> $code"

echo "== reverse proxy =="
rc=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ || true)
[[ "$rc" == "301" ]] && ok "http:// -> 301 redirect" || bad "http:// -> $rc (expected 301)"
hc=$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1/guacamole/ || true)
[[ "$hc" == "200" ]] && ok "https:// /guacamole/ -> 200" || bad "https:// /guacamole/ -> $hc"

echo "== guacadmin auth (through HTTPS proxy) =="
tok=$(curl -sk -d 'username=guacadmin&password=guacadmin' https://127.0.0.1/guacamole/api/tokens || true)
if echo "$tok" | grep -q '"authToken"'; then ok "guacadmin obtained an auth token"; else bad "guacadmin auth failed: $tok"; fi

echo "== extensions present =="
ls -1 /etc/guacamole/extensions/ 2>/dev/null | sed 's/^/  - /' || true

[[ $fail -eq 0 ]] && echo "CHECKS PASSED" || { echo "CHECKS FAILED"; exit 1; }
