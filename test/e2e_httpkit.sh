#!/bin/sh
# L5 for httpkit: the generated server over streamable HTTP, with rmcp's default behaviour (sessions, event-stream
# replies, loopback-only Host check). Needs curl.
# usage: sh test/e2e_httpkit.sh [CRATE_DIR]      (default /tmp/httpkit-out)
set -eu
dir=${1:-/tmp/httpkit-out}
port=18765
url="http://127.0.0.1:$port/mcp"
accept='Accept: application/json, text/event-stream'
ctype='Content-Type: application/json'

# make shares one cargo target dir (CARGO_TARGET_DIR), so the binary is there, or else inside the crate directory
bin=
for candidate in "${CARGO_TARGET_DIR:-$dir/target}/debug/httpkit" "$dir/target/debug/httpkit"; do
  if [ -x "$candidate" ]; then bin=$candidate; break; fi
done
[ -n "$bin" ] || { echo "FAIL: no httpkit binary under ${CARGO_TARGET_DIR:-$dir/target}/debug or $dir/target/debug"; exit 1; }

"$bin" &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT
i=0
until curl -s -o /dev/null "$url" 2>/dev/null; do
  i=$((i + 1)); [ $i -gt 100 ] && { echo "FAIL: server did not start"; exit 1; }
  sleep 0.1
done

init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
first=$(curl -si --max-time 5 -X POST "$url" -H "$accept" -H "$ctype" -d "$init" || true)
printf '%s\n' "$first" | cut -c1-220
sid=$(printf '%s\n' "$first" | tr -d '\r' | sed -n 's/^[Mm]cp-[Ss]ession-[Ii]d: *//p' | head -1)
[ -n "$sid" ] || { echo "FAIL: no mcp-session-id header"; exit 1; }
session="Mcp-Session-Id: $sid"

curl -s --max-time 5 -o /dev/null -X POST "$url" -H "$accept" -H "$ctype" -H "$session" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' || true
list=$(curl -s --max-time 5 -X POST "$url" -H "$accept" -H "$ctype" -H "$session" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' || true)
call=$(curl -s --max-time 5 -X POST "$url" -H "$accept" -H "$ctype" -H "$session" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}' || true)
bad=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -X POST "$url" -H "$accept" -H "$ctype" -H 'Host: evil.example' -d "$init" || true)
printf '%s\n%s\nforeign Host -> %s\n' "$list" "$call" "$bad" | cut -c1-220

fail() { echo "FAIL: $1"; exit 1; }
has() { printf '%s\n' "$2" | grep -qF -- "$3" || fail "should contain: $3"; }
has "$first" "$first" '"name":"httpkit"'; has "$first" "$first" '"tools"'
has "$list" "$list" '"name":"echo"'; has "$list" "$list" '"readOnlyHint":true'
has "$call" "$call" 'echo: hi'; has "$call" "$call" '"isError":false'
case "$bad" in 4*) ;; *) fail "a foreign Host header should be refused, got $bad";; esac
echo "OK: httpkit serves MCP over streamable HTTP with rmcp's default sessions and host check"
