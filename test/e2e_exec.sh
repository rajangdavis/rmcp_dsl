#!/bin/sh
# L5 for cmd_fn / script_fn: subprocess tools, including a command-injection check.
# usage: sh test/e2e_exec.sh [CRATE_DIR]      (default /tmp/exec-out)
set -eu
dir=${1:-/tmp/exec-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
c_upper='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"upper","arguments":{"text":"hello world"}}}'
# Shell metacharacters and a leading dash: they must come back as plain data.
c_echo='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"-n $(echo pwned) `id` \"q\" ; rm -rf /"}}}'
c_missing='{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"missing","arguments":{"text":"x"}}}'
c_fails='{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"fails","arguments":{"text":"x"}}}'
out=$( (printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$init" "$inited" "$c_upper" "$c_echo" "$c_missing" "$c_fails"; sleep 3) | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '"serverInfo":{"name":"execdemo","version":"0.1.0"}' || { echo "FAIL: serverInfo"; exit 1; }
printf '%s\n' "$out" | grep -q '"id":2,"result":{"content":\[{"type":"text","text":"HELLO WORLD"}\]' || { echo "FAIL: upper result"; exit 1; }
printf '%s\n' "$out" | grep -qF '"id":3,"result":{"content":[{"type":"text","text":"-n $(echo pwned) `id` \"q\" ; rm -rf /"}]' || { echo "FAIL: echo did not return the text unchanged"; exit 1; }
printf '%s\n' "$out" | grep -q 'pwned' && ! printf '%s\n' "$out" | grep -qF '$(echo pwned)' && { echo "FAIL: command substitution ran"; exit 1; }
printf '%s\n' "$out" | grep '"id":4,' | grep -qF 'error: cannot start definitely-not-a-real-program' || { echo "FAIL: missing program did not give a start error"; exit 1; }
printf '%s\n' "$out" | grep '"id":5,' | grep -qF 'error: sh exited with exit status: 3: boom' || { echo "FAIL: non-zero exit was not reported with its stderr"; exit 1; }
echo "OK: cmd_fn (stdin) and script_fn (argv) work; shell metacharacters stayed data; a missing program and a non-zero exit come back as errors"
