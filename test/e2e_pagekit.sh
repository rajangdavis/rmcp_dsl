#!/bin/sh
# L5 for pagekit: paged tools/prompts/resources/resource-templates lists and their cursors, over JSON-RPC.
# usage: sh test/e2e_pagekit.sh [CRATE_DIR]      (default /tmp/pagekit-out)
set -eu
dir=${1:-/tmp/pagekit-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
list() { printf '{"jsonrpc":"2.0","id":%s,"method":"%s","params":{"cursor":"%s"}}\n' "$1" "$2" "$3"; }
first() { printf '{"jsonrpc":"2.0","id":%s,"method":"%s"}\n' "$1" "$2"; }

out=$( { printf '%s\n%s\n' "$init" "$inited"
         first 2 tools/list;               list 3 tools/list c2;             list 4 tools/list zzz;   list 5 tools/list c9
         first 6 prompts/list;             list 7 prompts/list c2
         first 8 resources/list;           list 9 resources/list c2
         first 10 resources/templates/list; list 11 resources/templates/list c2
         first 12 resources/list
         sleep 3; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-260

fail() { echo "FAIL: $1"; exit 1; }
has() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" || fail "id $1 should contain: $3"; }
lacks() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" && fail "id $1 should not contain: $3" || true; }
# tools: the router lists them by name (one, three, two): two, then the last; the last page has no nextCursor
has 2 "$out" '"name":"one"'; has 2 "$out" '"name":"three"'; lacks 2 "$out" '"name":"two"'; has 2 "$out" '"nextCursor":"c2"'
has 3 "$out" '"name":"two"'; lacks 3 "$out" '"name":"one"'; lacks 3 "$out" 'nextCursor'
# a cursor the server did not issue, or one past the end, is invalid params
has 4 "$out" '"code":-32602'; has 4 "$out" 'invalid cursor'; has 5 "$out" '"code":-32602'
# prompts, resources and templates page the same way
has 6 "$out" '"name":"first"'; has 6 "$out" '"name":"second"'; lacks 6 "$out" '"name":"third"'; has 6 "$out" '"nextCursor":"c2"'
has 7 "$out" '"name":"third"'; lacks 7 "$out" 'nextCursor'
has 8 "$out" '"uri":"pagekit://a"'; has 8 "$out" '"uri":"pagekit://b"'; lacks 8 "$out" 'pagekit://c'; has 8 "$out" '"nextCursor":"c2"'
has 9 "$out" '"uri":"pagekit://c"'; lacks 9 "$out" 'nextCursor'
has 10 "$out" '"uriTemplate":"pagekit://x/{id}"'; has 10 "$out" '"uriTemplate":"pagekit://y/{id}"'; lacks 10 "$out" 'pagekit://z'; has 10 "$out" '"nextCursor":"c2"'
has 11 "$out" '"uriTemplate":"pagekit://z/{id}"'; lacks 11 "$out" 'nextCursor'
# the same first page every time (stable cursors)
[ "$(printf '%s\n' "$out" | grep '"id":8,' | sed 's/"id":8/"id":0/')" = "$(printf '%s\n' "$out" | grep '"id":12,' | sed 's/"id":12/"id":0/')" ] || fail "the first page should be the same each time"
echo "OK: pagekit pages tools, prompts, resources and resource templates with opaque cursors"
