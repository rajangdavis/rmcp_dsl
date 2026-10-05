#!/bin/sh
# L5 end to end: start the generated server, speak MCP over stdio, check add(2,3).
# usage: sh test/e2e_add.sh [CRATE_DIR]      (default /tmp/add-out)
# Build the crate first:  ruby exe/rmcp_dsl examples/add.rb -o /tmp/add-out
set -eu
dir=${1:-/tmp/add-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
list='{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
call='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add","arguments":{"a":2,"b":3}}}'
call2='{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"subtract","arguments":{"a":5,"b":3}}}'

# Keep stdin open for a couple of seconds so the server can answer before EOF.
out=$( (printf '%s\n%s\n%s\n%s\n%s\n' "$init" "$inited" "$list" "$call" "$call2"; sleep 3) | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '"serverInfo":{"name":"calculator","version":"0.1.0"}' || { echo "FAIL: serverInfo is not calculator 0.1.0"; exit 1; }
printf '%s\n' "$out" | grep -q '"name":"add"' || { echo "FAIL: tools/list does not contain add"; exit 1; }
printf '%s\n' "$out" | grep -q '"text":"5"' || { echo "FAIL: add(2,3) did not return 5"; exit 1; }
printf '%s\n' "$out" | grep -q '"name":"subtract"' || { echo "FAIL: tools/list does not contain subtract"; exit 1; }
printf '%s\n' "$out" | grep -q '"id":4,"result":{"content":\[{"type":"text","text":"2"}\]' || { echo "FAIL: subtract(5,3) did not return 2"; exit 1; }
echo "OK: add(2,3) = 5, subtract(5,3) = 2, serverInfo correct"
