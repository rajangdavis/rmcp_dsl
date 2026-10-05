#!/bin/sh
# L5 for mapkit: typed maps as tool input and structured output, over JSON-RPC.
# usage: sh test/e2e_mapkit.sh [CRATE_DIR]      (default /tmp/mapkit-out)
set -eu
dir=${1:-/tmp/mapkit-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$1" "$2" "$3"; }

out=$( { printf '%s\n%s\n' "$init" "$inited"
         printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
         call 3 tally '{"text":"b,a,b"}'
         call 4 tally '{"text":"b,a,b","labels":{"env":"prod"}}'
         call 5 lookup '{"scores":{"ann":3,"bob":5},"name":"bob"}'
         call 6 lookup '{"scores":{"ann":3,"bob":5},"name":"zed"}'
         call 7 lookup '{"scores":{"ann":"x"},"name":"ann"}'
         call 8 lookup '{"name":"ann"}'
         call 9 shape '{"text":"b,a"}'
         call 10 lookup '{"scores":{},"name":"x"}'
         sleep 3; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-240

fail() { echo "FAIL: $1"; exit 1; }
has() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" || fail "id $1 should contain: $3"; }
# the schema: a map is an object with additionalProperties
has 2 "$out" '"additionalProperties"'; has 2 "$out" '"outputSchema"'; has 2 "$out" 'Scores by name'
# a map comes back as a JSON object, keys sorted
has 3 "$out" '"counts":{"a":1,"b":2}'; has 3 "$out" '"labels":{"source":"tally"}'; has 3 "$out" '"first":"b"'
has 4 "$out" '"labels":{"env":"prod","source":"tally"}'
# reading a map: fetch with a default, keys, size, values, key?
has 5 "$out" 'bob: 5 of 2 (ann+bob), total 8, true'
has 6 "$out" 'zed: -1 of 2 (ann+bob), total 8, false'
has 10 "$out" 'x: -1 of 0 (), total 0, false'
# a value of the wrong type, or a missing map, is refused before the body runs
has 7 "$out" '"isError":true'; has 7 "$out" 'failed to deserialize parameters'
has 8 "$out" '"isError":true'; has 8 "$out" 'missing field `scores`'
# lists, floats and booleans as values
has 9 "$out" '"groups":{"all":["b","a"],"sorted":["a","b"]}'; has 9 "$out" '"weights":{"half":0.5}'; has 9 "$out" '"flags":{"empty":false}'
echo "OK: mapkit takes and returns typed maps with sorted keys and schemas that say additionalProperties"
