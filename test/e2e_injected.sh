#!/bin/sh
# L5 for the injected-Rust proof: one tool whose body calls Rust through rust_fn.
# usage: sh test/e2e_injected.sh [CRATE_DIR]      (default /tmp/injected-out)
set -eu
dir=${1:-/tmp/injected-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
c1='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"snake_case","arguments":{"text":"HelloWorld fooBar"}}}'
out=$( (printf '%s\n%s\n%s\n' "$init" "$inited" "$c1"; sleep 3) | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '"serverInfo":{"name":"injected","version":"0.1.0"}' || { echo "FAIL: serverInfo"; exit 1; }
printf '%s\n' "$out" | grep -q '"id":2,"result":{"content":\[{"type":"text","text":"hello_world_foo_bar"}\]' || { echo "FAIL: snake_case result"; exit 1; }
echo "OK: injected Rust (heck) called from Ruby"
