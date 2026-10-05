#!/bin/sh
# L5 for bindings: a crate-backed binding (Heck) and a binding compiled from Ruby (Words).
# usage: sh test/e2e_bindings.sh [CRATE_DIR]      (default /tmp/bindings-out)
set -eu
dir=${1:-/tmp/bindings-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":{"text":"%s"}}}\n' "$1" "$2" "$3"; }
out=$( { printf '%s\n%s\n' "$init" "$inited"
         call 2 snake_case "HelloWorld fooBar"
         call 3 kebab_case "HelloWorld fooBar"
         call 4 upper_camel_case "hello_world foo-bar"
         call 5 shout "hello"
         call 6 bracket "  hi  "
         call 7 snake_case ""
         sleep 3; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-200
fail() { echo "FAIL: $1"; exit 1; }
has() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" || fail "id $1 should contain: $3"; }
printf '%s\n' "$out" | grep -q '"serverInfo":{"name":"bindings","version":"0.1.0"}' || fail "serverInfo"
has 2 "$out" '"text":"hello_world_foo_bar"'
has 3 "$out" '"text":"hello-world-foo-bar"'
has 4 "$out" '"text":"HelloWorldFooBar"'
has 5 "$out" '"text":"HELLO!"'
has 6 "$out" '"text":"[hi]"'
has 7 "$out" '"text":""'
echo "OK: crate-backed (Heck) and Ruby-compiled (Words) bindings work"
