#!/bin/sh
# L5 for rust_file: a tool whose body calls a function from a hand-written .rs module.
# usage: sh test/e2e_hooked.sh [CRATE_DIR]      (default /tmp/hooked-out)
set -eu
dir=${1:-/tmp/hooked-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
c1='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"shout","arguments":{"text":"hello world"}}}'
out=$( (printf '%s\n%s\n%s\n' "$init" "$inited" "$c1"; sleep 3) | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '"serverInfo":{"name":"hooked","version":"0.1.0"}' || { echo "FAIL: serverInfo"; exit 1; }
printf '%s\n' "$out" | grep -q '"id":2,"result":{"content":\[{"type":"text","text":"HELLO WORLD!"}\]' || { echo "FAIL: shout result"; exit 1; }
test -f "$dir/src/loud.rs" || { echo "FAIL: src/loud.rs was not written"; exit 1; }
echo "OK: existing Rust file called from Ruby (module loud)"
