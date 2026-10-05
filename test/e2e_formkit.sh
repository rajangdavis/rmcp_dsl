#!/bin/sh
# L5 for formkit: list fields, a nested object, defaults and a format, over JSON-RPC.
# usage: sh test/e2e_formkit.sh [CRATE_DIR]      (default /tmp/formkit-out)
set -eu
dir=${1:-/tmp/formkit-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"register","arguments":%s}}\n' "$1" "$2"; }
addr='"address":{"city":"Austin","zip":"78701"}'

out=$( { printf '%s\n%s\n' "$init" "$inited"
         printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
         call 3 "{\"email\":\"a@b.co\",\"tags\":[\"x\",\"y\"],\"scores\":[1,2,3],\"level\":4,\"greeting\":\"hi\",$addr}"
         call 4 "{\"email\":\"a@b.co\",\"tags\":[\"x\"],\"scores\":[],$addr}"
         call 5 "{\"email\":\"a@b.co\",\"tags\":[],\"scores\":[1],$addr}"
         call 6 "{\"email\":\"a@b.co\",\"tags\":[\"a\",\"b\",\"c\",\"d\"],\"scores\":[1],$addr}"
         call 7 '{"email":"a@b.co","tags":["x"],"scores":[1],"address":{"city":"Austin","zip":"abc"}}'
         call 8 "{\"email\":\"a@b.co\",\"tags\":[\"x\"],\"scores\":[1],\"level\":9,$addr}"
         call 9 '{"email":"a@b.co","tags":["x"],"scores":[1]}'
         sleep 3; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-240

fail() { echo "FAIL: $1"; exit 1; }
has() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" || fail "id $1 should contain: $3"; }
has 2 "$out" '"format":"email"'; has 2 "$out" '"minItems":1'; has 2 "$out" '"maxItems":3'
has 2 "$out" '"default":1'; has 2 "$out" '"default":"hello"'; has 2 "$out" '"address"'
has 3 "$out" 'hi a@b.co: level 4, tags x+y, total 6, Austin 78701'
has 4 "$out" 'hello a@b.co: level 1, tags x, total 0, Austin 78701'
for id in 5 6 7 8; do has $id "$out" '"isError":true'; done
has 5 "$out" 'tags'; has 6 "$out" 'tags'; has 7 "$out" 'zip'; has 8 "$out" 'level'
has 9 "$out" 'missing field `address`'
echo "OK: formkit takes lists, nested objects, defaults and formats, and enforces their limits"
