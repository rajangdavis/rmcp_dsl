#!/bin/sh
# Slow failure paths of the subprocess helper: the 10 s timeout and the 1 MB output cap.
# usage: sh test/e2e_exec_slow.sh [CRATE_DIR]      (default /tmp/exec-out; takes about 15 s)
set -eu
dir=${1:-/tmp/exec-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
c_sleep='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sleeps","arguments":{"text":"x"}}}'
c_flood='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"floods","arguments":{"text":"x"}}}'
out=$( (printf '%s\n%s\n%s\n%s\n' "$init" "$inited" "$c_sleep" "$c_flood"; sleep 15) | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-300
printf '%s\n' "$out" | grep '"id":2,' | grep -qF 'error: sh timed out after 10 s' || { echo "FAIL: a script that sleeps 30 s was not timed out"; exit 1; }
printf '%s\n' "$out" | grep '"id":3,' | grep -qF 'error: sh produced more than 1000000 bytes of output' || { echo "FAIL: 2 MB of output was not refused"; exit 1; }
echo "OK: timeout after 10 s and the 1 MB output cap both come back as errors"
