#!/bin/sh
# L5 for statkit: a tool with an output returns structured content and publishes an output schema.
# usage: sh test/e2e_statkit.sh [CRATE_DIR]      (default /tmp/statkit-out)
set -eu
dir=${1:-/tmp/statkit-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"stats","arguments":{"text":"%s"}}}\n' "$1" "$2"; }

out=$( { printf '%s\n%s\n' "$init" "$inited"
         printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
         call 3 'b,a,b'
         call 4 'B,A'
         call 5 ','
         call 6 ''
         sleep 3; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-260

fail() { echo "FAIL: $1"; exit 1; }
has() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" || fail "id $1 should contain: $3"; }
has 2 "$out" '"outputSchema"'; has 2 "$out" '"Counts"'; has 2 "$out" '"unique"'
has 2 "$out" 'The first item'; has 2 "$out" 'Whether the text is already upper case'
has 3 "$out" '"structuredContent"'; has 3 "$out" '"counts":{"items":3,"unique":2}'
has 3 "$out" '"items":["B","A","B"]'; has 3 "$out" '"first":"b"'; has 3 "$out" '"shout":false'
has 3 "$out" '"isError":false'
has 4 "$out" '"shout":true'
has 5 "$out" '"isError":true'; has 5 "$out" 'no items'
has 6 "$out" '"isError":true'; has 6 "$out" 'text'
echo "OK: statkit returns structured content that matches its published output schema"
