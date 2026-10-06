#!/bin/sh
# L5 for httpoauth: the streamable HTTP server as an OAuth resource server. A local fake issuer (test/support/oauth_issuer.rb)
# signs real RS256 tokens and serves their JWKS. Only the valid token gets in; expired, wrong-audience, wrong-issuer,
# tampered, unknown-key, `alg: none`, HS256 and missing tokens are all 401 with a challenge that points at the
# protected-resource metadata, which is served without a token. Needs curl and ruby.
# usage: sh test/e2e_httpoauth.sh [CRATE_DIR]      (default /tmp/httpoauth-out)
set -eu
dir=${1:-/tmp/httpoauth-out}
audience=mcp-e2e
issuer_port=18766
port=8766
base="http://127.0.0.1:$port"
url="$base/mcp"
accept='Accept: application/json, text/event-stream'
ctype='Content-Type: application/json'
fail() { echo "FAIL: $1"; exit 1; }

bin=
for candidate in "${CARGO_TARGET_DIR:-$dir/target}/debug/httpoauth" "$dir/target/debug/httpoauth"; do
  if [ -x "$candidate" ]; then bin=$candidate; break; fi
done
[ -n "$bin" ] || fail "no httpoauth binary under ${CARGO_TARGET_DIR:-$dir/target}/debug or $dir/target/debug"

tokens=$(mktemp -d)
ruby "$(dirname "$0")/support/oauth_issuer.rb" "$issuer_port" "$tokens" "$audience" &
issuer_pid=$!
pid=
trap 'kill $issuer_pid $pid 2>/dev/null || true; wait $issuer_pid $pid 2>/dev/null || true; rm -rf "$tokens"' EXIT
i=0
until curl -s -o /dev/null "http://127.0.0.1:$issuer_port/keys" 2>/dev/null; do
  i=$((i + 1)); [ $i -gt 100 ] && fail "the fake issuer did not start"
  sleep 0.1
done

# no issuer configured: the server does not start, and names the variable
set +e
none=$(env -u OAUTH_ISSUER OAUTH_AUDIENCE="$audience" "$bin" 2>&1 >/dev/null)
code=$?
set -e
[ "$code" = 2 ] || fail "starting without OAUTH_ISSUER should exit 2, got $code: $none"
printf '%s\n' "$none" | grep -qF 'OAUTH_ISSUER' || fail "the message should name OAUTH_ISSUER"

OAUTH_ISSUER="http://127.0.0.1:$issuer_port" OAUTH_AUDIENCE="$audience" "$bin" &
pid=$!
i=0
until curl -s -o /dev/null "$url" 2>/dev/null; do
  i=$((i + 1)); [ $i -gt 100 ] && fail "server did not start"
  sleep 0.1
done

init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'

# post_status [HEADER]: the HTTP status of an initialize, with that header if there is one
post_status() {
  if [ -n "${1:-}" ]; then
    curl -s --max-time 5 -o /dev/null -w '%{http_code}' -X POST "$url" -H "$accept" -H "$ctype" -H "$1" -d "$init"
  else
    curl -s --max-time 5 -o /dev/null -w '%{http_code}' -X POST "$url" -H "$accept" -H "$ctype" -d "$init"
  fi
}
metadata_url="$base/.well-known/oauth-protected-resource"

[ "$(post_status)" = 401 ] || fail "no token should be 401"
challenge=$(curl -si --max-time 5 -X POST "$url" -H "$accept" -H "$ctype" -d "$init" | tr -d '\r' | grep -i '^www-authenticate:' || true)
printf '%s\n' "$challenge" | grep -qF "resource_metadata=\"$metadata_url\"" || fail "the challenge should point at $metadata_url, got: $challenge"
printf '%s\n' "$challenge" | grep -qF 'error=' && fail "a request with no token should not carry an error code, got: $challenge"

for bad in expired wrong_aud wrong_iss no_exp bad_sig unknown_kid alg_none hs256; do
  status=$(post_status "Authorization: Bearer $(cat "$tokens/$bad.jwt")")
  [ "$status" = 401 ] || fail "the $bad token should be 401, got $status"
done
[ "$(post_status 'Authorization: Bearer not-a-jwt')" = 401 ] || fail "garbage should be 401"
bad_challenge=$(curl -si --max-time 5 -X POST "$url" -H "$accept" -H "$ctype" -H "Authorization: Bearer $(cat "$tokens/expired.jwt")" -d "$init" | tr -d '\r' | grep -i '^www-authenticate:' || true)
printf '%s\n' "$bad_challenge" | grep -qF 'error="invalid_token"' || fail "a bad token should carry error=invalid_token, got: $bad_challenge"
echo "401 for every bad token: ok ($bad_challenge)"

meta=$(curl -s --max-time 5 "$metadata_url")
printf '%s\n' "$meta"
printf '%s\n' "$meta" | grep -qF "\"resource\":\"$url\"" || fail "metadata should name the resource $url"
printf '%s\n' "$meta" | grep -qF "http://127.0.0.1:$issuer_port" || fail "metadata should name the issuer"

[ "$(post_status "authorization: bearer $(cat "$tokens/valid.jwt")")" = 200 ] || fail "the scheme is case-insensitive: a lower-case bearer with a valid token should be 200"
auth="Authorization: Bearer $(cat "$tokens/valid.jwt")"
first=$(curl -si --max-time 5 -X POST "$url" -H "$accept" -H "$ctype" -H "$auth" -d "$init" || true)
printf '%s\n' "$first" | cut -c1-220
sid=$(printf '%s\n' "$first" | tr -d '\r' | sed -n 's/^[Mm]cp-[Ss]ession-[Ii]d: *//p' | head -1)
[ -n "$sid" ] || fail "no mcp-session-id header with a valid token"
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
printf '%s\n' "$first" | grep -qF '"name":"httpoauth"' || fail "serverInfo"
printf '%s\n' "$reversed" | grep -qF 'cba' || fail "reverse should return cba"
printf '%s\n' "$loud" | grep -qF 'HI!' || fail "loud should return HI!"
echo "OK: httpoauth accepts only a valid issuer-signed token and serves MCP with it"
