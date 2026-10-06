#!/bin/sh
# L5 for httpauth: the streamable HTTP server behind `transport :http, auth_setting:`. Without the bearer token (no
# header, a wrong token, another scheme) the layer answers 401 with a WWW-Authenticate challenge; with it, MCP works
# and both tools answer (one plain Ruby, one injected Rust). Without the setting the server refuses to start. Needs curl.
# usage: sh test/e2e_httpauth.sh [CRATE_DIR]      (default /tmp/httpauth-out)
set -eu
dir=${1:-/tmp/httpauth-out}
token=s3cret-token
port=8765
url="http://127.0.0.1:$port/mcp"
accept='Accept: application/json, text/event-stream'
ctype='Content-Type: application/json'
fail() { echo "FAIL: $1"; exit 1; }

# make shares one cargo target dir (CARGO_TARGET_DIR), so the binary is there, or else inside the crate directory
bin=
for candidate in "${CARGO_TARGET_DIR:-$dir/target}/debug/httpauth" "$dir/target/debug/httpauth"; do
  if [ -x "$candidate" ]; then bin=$candidate; break; fi
done
[ -n "$bin" ] || fail "no httpauth binary under ${CARGO_TARGET_DIR:-$dir/target}/debug or $dir/target/debug"

# a server with no token configured does not start, and says which variable is missing (never a value)
set +e
none=$(env -u HTTPAUTH_TOKEN "$bin" 2>&1 >/dev/null)
code=$?
set -e
[ "$code" = 2 ] || fail "starting $bin without HTTPAUTH_TOKEN should exit 2, got $code: $none"
printf '%s\n' "$none" | grep -qF 'HTTPAUTH_TOKEN' || fail "the message should name HTTPAUTH_TOKEN"

HTTPAUTH_TOKEN="$token" "$bin" &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT
i=0
until curl -s -o /dev/null "$url" 2>/dev/null; do
  i=$((i + 1)); [ $i -gt 100 ] && fail "server did not start"
  sleep 0.1
done

init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'

# status HEADER-OR-EMPTY: the HTTP status of an initialize with that Authorization header
status() {
  if [ -n "$1" ]; then
    curl -s --max-time 5 -o /dev/null -w '%{http_code}' -X POST "$url" -H "$accept" -H "$ctype" -H "$1" -d "$init"
  else
    curl -s --max-time 5 -o /dev/null -w '%{http_code}' -X POST "$url" -H "$accept" -H "$ctype" -d "$init"
  fi
}
[ "$(status '')" = 401 ] || fail "no Authorization header should be 401"
[ "$(status 'Authorization: Bearer wrong')" = 401 ] || fail "a wrong token should be 401"
[ "$(status "authorization: bearer $token")" = 200 ] || fail "the scheme is case-insensitive: a lower-case bearer with the right token should be 200"
[ "$(status "Authorization: Basic $token")" = 401 ] || fail "another scheme should be 401"
[ "$(status "Authorization: Bearer ${token}x")" = 401 ] || fail "a longer token should be 401"
challenge=$(curl -si --max-time 5 -X POST "$url" -H "$accept" -H "$ctype" -d "$init" | tr -d '\r' | grep -i '^www-authenticate:' || true)
printf '%s\n' "$challenge" | grep -qi 'bearer' || fail "a 401 should carry WWW-Authenticate: Bearer"
echo "401 without a valid token: ok ($challenge)"

auth="Authorization: Bearer $token"
first=$(curl -si --max-time 5 -X POST "$url" -H "$accept" -H "$ctype" -H "$auth" -d "$init" || true)
printf '%s\n' "$first" | cut -c1-220
sid=$(printf '%s\n' "$first" | tr -d '\r' | sed -n 's/^[Mm]cp-[Ss]ession-[Ii]d: *//p' | head -1)
[ -n "$sid" ] || fail "no mcp-session-id header with the right token"
session="Mcp-Session-Id: $sid"
curl -s --max-time 5 -o /dev/null -X POST "$url" -H "$accept" -H "$ctype" -H "$auth" -H "$session" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' || true
call() {
  curl -s --max-time 5 -X POST "$url" -H "$accept" -H "$ctype" -H "$auth" -H "$session" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":$1,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\",\"arguments\":{\"text\":\"$3\"}}}" || true
}
reversed=$(call 2 reverse abc)
loud=$(call 3 loud hi)
printf '%s\n%s\n' "$reversed" "$loud" | cut -c1-220
printf '%s\n' "$first" | grep -qF '"name":"httpauth"' || fail "serverInfo"
printf '%s\n' "$reversed" | grep -qF 'cba' || fail "reverse should return cba"
printf '%s\n' "$loud" | grep -qF 'HI!' || fail "loud should return HI!"
echo "OK: httpauth refuses requests without the bearer token and serves MCP with it"
