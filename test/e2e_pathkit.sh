#!/bin/sh
# L5 for pathkit: resource templates with the RFC 6570 operators {+path}, {a,b}, {x*} and {?q,limit}, over JSON-RPC.
# usage: sh test/e2e_pathkit.sh [CRATE_DIR]      (default /tmp/pathkit-out)
set -eu
dir=${1:-/tmp/pathkit-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
read_uri() { printf '{"jsonrpc":"2.0","id":%s,"method":"resources/read","params":{"uri":"%s"}}\n' "$1" "$2"; }

out=$( { printf '%s\n%s\n' "$init" "$inited"
         printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"resources/templates/list"}'
         read_uri 3 'pathkit://files/a/b/c.txt'
         read_uri 4 'pathkit://files/a%20b/c'
         read_uri 5 'pathkit://files/'
         read_uri 6 'pathkit://pairs/x,y'
         read_uri 7 'pathkit://pairs/x'
         read_uri 8 'pathkit://tagged/a,b%2Cc,d'
         read_uri 9 'pathkit://tagged/'
         read_uri 10 'pathkit://search'
         read_uri 11 'pathkit://search?q=hello%20world&limit=5'
         read_uri 12 'pathkit://search?limit=3&other=1'
         read_uri 13 'pathkit://search?q=a&q=b'
         read_uri 14 'pathkit://search?q=%zz'
         sleep 3; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-260

fail() { echo "FAIL: $1"; exit 1; }
has() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" || fail "id $1 should contain: $3"; }
# the templates are listed as written
has 2 "$out" '"uriTemplate":"pathkit://files/{+path}"'; has 2 "$out" '"uriTemplate":"pathkit://pairs/{left,right}"'
has 2 "$out" '"uriTemplate":"pathkit://tagged/{tags*}"'; has 2 "$out" '"uriTemplate":"pathkit://search{?q,limit}"'
# {+path} takes slashes and decodes escapes; the empty path is still a value
has 3 "$out" 'contents of a/b/c.txt'; has 4 "$out" 'contents of a b/c'; has 5 "$out" 'contents of '
# {left,right}: two values; one value is not a match
has 6 "$out" '"text":"x+y"'; has 7 "$out" '"code":-32002'
# {tags*}: a list, each item decoded (%2C is a comma inside an item); nothing is the empty list
has 8 "$out" '3 tags: a|b,c|d'; has 9 "$out" '0 tags: '
# {?q,limit}: absent is nil, the order is free, other parameters are ignored, a repeat or a bad escape is invalid params
has 10 "$out" 'q=- limit=10'; has 11 "$out" 'q=hello world limit=5'; has 12 "$out" 'q=- limit=3'
has 13 "$out" '"code":-32602'; has 13 "$out" 'invalid query parameter `q`: it appears twice in the query'
has 14 "$out" '"code":-32602'; has 14 "$out" 'invalid query parameter `q`'
echo "OK: pathkit reads uris with {+path}, {a,b}, {x*} and {?q,limit}"
