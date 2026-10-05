#!/bin/sh
# L5 for contentkit: image, audio, resource link and embedded resource content in tool results, over JSON-RPC.
# usage: sh test/e2e_contentkit.sh [CRATE_DIR]      (default /tmp/contentkit-out)
set -eu
dir=${1:-/tmp/contentkit-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$1" "$2" "$3"; }

out=$( { printf '%s\n%s\n' "$init" "$inited"
         call 2 logo '{"label":"acme"}'
         call 3 logo '{"label":""}'
         call 4 beep '{"label":"x"}'
         call 5 link '{"label":"todo"}'
         call 6 embed '{"label":"bob"}'
         sleep 3; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-300

fail() { echo "FAIL: $1"; exit 1; }
has() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" || fail "id $1 should contain: $3"; }
# a text block and an image with annotations, in order
has 2 "$out" '"content":[{"type":"text","text":"Logo for acme"},{"type":"image","data":"iVBORw0KGgo'
has 2 "$out" '"mimeType":"image/png","annotations":{"audience":["user"],"priority":0.5}}]'
# a raise in a content tool is still an error result
has 3 "$out" '"isError":true'; has 3 "$out" 'label is empty'
# audio
has 4 "$out" '"type":"audio","data":"UklGRiQAAABXQVZFZm10'; has 4 "$out" '"mimeType":"audio/wav"'
# a resource link: every field the DSL gave it
has 5 "$out" '"type":"resource_link","uri":"contentkit://notes/todo","name":"todo","title":"Note todo"'
has 5 "$out" '"description":"A note by name","mimeType":"text/plain","size":120'; has 5 "$out" '"annotations":{"audience":["assistant"]}'
# embedded resources: text and a blob
has 6 "$out" '"type":"resource","resource":{"uri":"contentkit://readme/bob","mimeType":"text/markdown","text":"Hello, bob"}'
has 6 "$out" '"annotations":{"audience":["user","assistant"],"priority":0.25}'
has 6 "$out" '"uri":"contentkit://blob","mimeType":"application/octet-stream","blob":"aGk="'
echo "OK: contentkit returns image, audio, resource link and embedded resource content"
