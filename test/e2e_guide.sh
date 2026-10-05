#!/bin/sh
# L5 for guide: a server with no tools, only a prompt and a resource.
# usage: sh test/e2e_guide.sh [CRATE_DIR]      (default /tmp/guide-out)
set -eu
dir=${1:-/tmp/guide-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
rpc() { printf '{"jsonrpc":"2.0","id":%s,"method":"%s","params":%s}\n' "$1" "$2" "$3"; }

out=$( { printf '%s\n%s\n' "$init" "$inited"
         printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
         rpc 3 prompts/get '{"name":"explain","arguments":{"topic":"caching"}}'
         printf '%s\n' '{"jsonrpc":"2.0","id":4,"method":"resources/list"}'
         rpc 5 resources/read '{"uri":"guide://intro"}'
         printf '%s\n' '{"jsonrpc":"2.0","id":6,"method":"prompts/list"}'
         sleep 3; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-200

fail() { echo "FAIL: $1"; exit 1; }
has() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" || fail "id $1 should contain: $3"; }
has 1 "$out" '"name":"guide"'; has 1 "$out" '"prompts"'; has 1 "$out" '"resources"'
has 1 "$out" '"title":"Guide"'; has 1 "$out" '"description":"A tiny guide with one prompt and one resource"'
has 1 "$out" '"websiteUrl":"https://example.com/guide"'; has 1 "$out" '"src":"https://example.com/guide.png"'
has 2 "$out" '"tools":[]'
has 3 "$out" 'Explain caching using the guide.'; has 3 "$out" '"role":"assistant"'
has 3 "$out" 'I am ready to explain things using the guide.'
has 6 "$out" '"title":"Explain a topic"'; has 6 "$out" 'https://example.com/explain.png'
has 4 "$out" 'https://example.com/intro.png'
has 4 "$out" '"audience":["user","assistant"]'; has 4 "$out" '"priority":0.5'
has 4 "$out" '"uri":"guide://intro"'; has 4 "$out" 'Guide introduction'
has 5 "$out" '# Guide'
echo "OK: guide serves a prompt and a resource with no tools"
