#!/bin/sh
# L5 for schemakit: a hand-written input schema is what tools/list publishes, and the tool still takes its fields.
# usage: sh test/e2e_schemakit.sh [CRATE_DIR]      (default /tmp/schemakit-out)
set -eu
dir=${1:-/tmp/schemakit-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$1" "$2" "$3"; }

out=$( { printf '%s\n%s\n' "$init" "$inited"
         printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
         call 3 search '{"query":"cats"}'
         call 4 search '{"query":"cats","limit":5}'
         call 5 search '{"limit":5}'
         sleep 3; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-300

fail() { echo "FAIL: $1"; exit 1; }
has() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" || fail "id $1 should contain: $3"; }
# the schema is the one written in the file, not one made from the fields
has 2 "$out" '"title":"Search arguments"'; has 2 "$out" '"examples":["cats","dogs"]'; has 2 "$out" '"minimum":1'
has 2 "$out" '"additionalProperties":false'; has 2 "$out" '"required":["query"]'
# the tool reads its arguments through the fields
has 3 "$out" 'cats|10'; has 4 "$out" 'cats|5'
has 5 "$out" '"isError":true'; has 5 "$out" 'missing field `query`'
echo "OK: schemakit publishes the schema written in the file and still reads its arguments through the fields"
