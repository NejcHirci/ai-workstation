#!/usr/bin/env bash
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1"; fail=$((fail+1)); }
expect_fail() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
expect_ok()   { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

echo "== Network isolation =="
expect_fail "https://example.com is unreachable"          curl -sS -m 6 https://example.com
expect_fail "http://1.1.1.1 (direct IP) is unreachable"   curl -sS -m 6 http://1.1.1.1
expect_fail "https://1.1.1.1 is unreachable"              curl -sS -m 6 -k https://1.1.1.1
expect_fail "IPv6 is unreachable"                         curl -6 -sS -m 6 -k "https://[2606:4700:4700::1111]"
expect_fail "DNS lookup fails"                            getent hosts example.com
expect_fail "raw TCP to 8.8.8.8:53 fails"                 timeout 5 bash -c 'exec 3<>/dev/tcp/8.8.8.8/53'
expect_fail "no resolv.conf nameserver"                   grep -q '^nameserver' /etc/resolv.conf

echo "== Gateway =="
expect_ok   "gateway /healthz"                            curl -fsS -m 6 http://llm-gateway:8080/healthz
expect_fail "gateway refuses unknown path"                curl -fsS -m 6 http://llm-gateway:8080/admin
expect_fail "gateway refuses DELETE"                      curl -fsS -m 6 -X DELETE http://llm-gateway:8080/v1/models
code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 http://llm-gateway:8080/v1/models)
if [ "$code" = "200" ]; then ok "gateway -> Cortecs /v1/models returns 200"; else bad "gateway -> Cortecs /v1/models returned $code (401 = bad key, 502/504 = egress or DNS problem)"; fi

if [ -n "${HTTPS_PROXY:-}" ]; then
  echo "== Docs proxy (verify-sandbox -Docs) =="
  expect_fail "proxy refuses a domain that is not allowlisted"   curl -sS -m 15 https://example.net
  expect_fail "proxy refuses a non-443 port"                     curl -sS -m 10 https://doc.qt.io:8443
  allowed="${VERIFY_ALLOWED_HOST:-doc.qt.io}"
  expect_ok   "proxy allows an allowlisted domain ($allowed)"    curl -fsS -m 20 -o /dev/null "https://$allowed"
fi

echo "== Secrets and identity =="
if env | grep -qiE 'cortecs|api_key|token|secret'; then bad "no secrets in agent environment"; else ok "no secrets in agent environment"; fi
[ "$(id -u)" != "0" ] && ok "not running as root (uid $(id -u))" || bad "running as root"
grep -q '^CapEff:\s*0000000000000000' /proc/self/status && ok "no effective capabilities" || bad "capabilities present"
grep -q '^NoNewPrivs:\s*1' /proc/self/status && ok "no-new-privileges set" || bad "no-new-privileges missing"

echo "== Filesystem protections =="
expect_fail "root filesystem is read-only"                touch /usr/.write-test
expect_fail "skills folder is read-only"                  touch /home/agent/.agents/skills/.write-test
expect_fail "opencode config is read-only"                touch /etc/opencode/.write-test
expect_ok   "workspace is writable"                       bash -c 'touch /workspace/.write-test && rm /workspace/.write-test'
if [ -d /workspace/.git/hooks ]; then
  expect_fail ".git/hooks is read-only"                   touch /workspace/.git/hooks/.write-test
  expect_fail ".git/config is read-only"                  bash -c 'echo >> /workspace/.git/config'
else
  echo "SKIP  .git protections (workspace has no .git directory)"
fi
expect_ok   "skills visible"                              bash -c 'ls /home/agent/.agents/skills | grep -q .'
expect_ok   "toolchain present (cmake, ninja, clang-format)" bash -c 'cmake --version && ninja --version && clang-format --version'

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]