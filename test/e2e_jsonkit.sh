#!/bin/sh
# L5 for jsonkit: a binding's own type (Json::Value) as a tool field, a local and part of a structured result.
# usage: sh test/e2e_jsonkit.sh [CRATE_DIR]      (default /tmp/jsonkit-out)
set -eu
dir=${1:-/tmp/jsonkit-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$1" "$2" "$3"; }
doc='{"a":[1,2,{"b":"x","c":null}],"n":41,"s":"hi"}'

out=$( { printf '%s\n%s\n' "$init" "$inited"
         printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
         call 3 kind_of_text '{"text":"[1,2]"}'
         call 4 kind_of_text '{"text":"{oops"}'
         call 5 pick "{\"doc\":$doc,\"path\":\"/a/2/b\"}"
         call 6 pick "{\"doc\":$doc,\"path\":\"/zzz\"}"
         call 7 peek "{\"doc\":$doc,\"path\":\"/a/2\"}"
         call 8 names "{\"doc\":$doc,\"path\":\"\"}"
         call 9 names "{\"doc\":$doc,\"path\":\"/s\"}"
         call 10 total "{\"doc\":$doc,\"path\":\"/n\"}"
         call 11 total "{\"doc\":$doc,\"path\":\"/s\"}"
         call 12 pick '{"path":"/a"}'
         call 13 pick '{"doc":null,"path":""}'
         sleep 3; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-260

fail() { echo "FAIL: $1"; exit 1; }
has() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" || fail "id $1 should contain: $3"; }
# the schema of a Json::Value field accepts any JSON (serde_json::Value is schemars' "anything"), the result has a schema
has 2 "$out" '"name":"pick"'; has 2 "$out" 'any JSON document'; has 2 "$out" '"outputSchema"'
# parse text into a document, then ask what it is; invalid text is an error result
has 3 "$out" 'array'
has 4 "$out" '"isError":true'; has 4 "$out" 'not valid JSON'
# a document arrives as a tool field and a pointer finds a value inside it
has 5 "$out" '"text":"\"x\""'
has 6 "$out" '"isError":true'; has 6 "$out" 'nothing at /zzz'
# a document comes back inside a structured result: serde_json keeps object members sorted
has 7 "$out" '"structuredContent":{"kind":"object","value":{"b":"x","c":null}}'
has 8 "$out" 'a,n,s'
has 9 "$out" '/s is a string, not an object'
has 10 "$out" '"text":"42"'
has 11 "$out" '/s is not an integer'
# a document is required, and JSON null is a document (it is not the same as missing)
has 12 "$out" '"isError":true'; has 12 "$out" 'missing field `doc`'
has 13 "$out" '"text":"null"'
echo "OK: jsonkit passes a binding's own JSON type through tool fields, locals and structured results"
