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
         call 11 pick '{"text":"abc123","scores":{"ann":5,"bob":2,"cy":9},"threshold":4}'
         call 12 pick '{"text":"日本1","scores":{"ann":5},"threshold":10}'
         call 13 pick '{"text":"abc","scores":{"ann":5},"threshold":10}'
         call 14 check_scores '{"scores":{"ann":3,"bob":5},"name":"ok"}'
         call 15 check_scores '{"scores":{"ann":3,"bad":-1},"name":"ok"}'
         call 16 org '{"roster":{"ann":{"name":"Ann","level":3},"bob":{"name":"Bob","level":1}},"grid":{"a":{"b":7},"c":{"d":2}}}'
         call 17 org '{"roster":{"ann":{"name":"Ann","level":3}},"extra":{"zed":{"name":"Zed","level":9}},"grid":{}}'
         call 18 org '{"roster":{"bad":{"name":"Bad","level":-1}},"grid":{}}'
         call 19 org '{"roster":{"":{"name":"N","level":1}},"grid":{}}'
         call 20 org '{"roster":{"ann":{"name":"Ann","level":"x"}},"grid":{}}'
         sleep 3; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-240

fail() { echo "FAIL: $1"; exit 1; }
has() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" || fail "id $1 should contain: $3"; }
count() { printf '%s\n' "$1" | grep -oF -- "$2" | wc -l | tr -d ' '; }
hasn() { [ "$(count "$2" "$3")" -ge "$4" ] || fail "id $1 should contain at least $4 of: $3"; }
# the schema: a map is an object with additionalProperties
has 2 "$out" '"additionalProperties"'; has 2 "$out" '"outputSchema"'; has 2 "$out" 'Scores by name'
# a map's entry count is bounded in the schema too (min_items: on the labels map, an object property)
has 2 "$out" '"minProperties":1'
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
# =~ gives the character index of the first match, and map map/select/reject follow Ruby
has 11 "$out" '"index":3'; has 11 "$out" '"kept":{"ann":5,"cy":9}'; has 11 "$out" '"dropped":{"bob":2}'; has 11 "$out" '"names":["ann=5","cy=9"]'
has 12 "$out" '"index":2'; has 12 "$out" '"kept":{}'; has 12 "$out" '"dropped":{"ann":5}'
has 13 "$out" '"index":-1'; has 13 "$out" '"dropped":{"ann":5}'
# each on a map runs the block for its effects; a negative score raises inside the loop.
has 14 "$out" '"text":"ok: 2 scores"'
has 15 "$out" '"isError":true'; has 15 "$out" 'negative score for bad'
# a map of objects and a map of maps: nested additionalProperties in both schemas
has 2 "$out" '"roster"'; has 2 "$out" '"grid"'; has 2 "$out" '"matrix"'
hasn 2 "$out" '"additionalProperties"' 3
# indexing a map of objects (with &.), iterating, selecting and merging; values, and nested map indexing
has 16 "$out" '"lines":["Ann=3","Bob=1"]'; has 16 "$out" '"total":9'; has 16 "$out" '"summary":"Ann 7 kept=1"'
has 16 "$out" '"matrix":{"a":{"b":7},"c":{"d":2}}'
has 17 "$out" '"lines":["Ann=3","Zed=9"]'; has 17 "$out" '"total":0'; has 17 "$out" '"summary":"Ann -1 kept=1"'
# a map value that breaks the object own min: is refused by check() before the body runs
has 18 "$out" '"isError":true'; has 18 "$out" 'below the minimum of 0'
# a bad key raises inside each
has 19 "$out" '"isError":true'; has 19 "$out" 'bad handle '
# a value of the wrong type is refused before the body runs
has 20 "$out" '"isError":true'; has 20 "$out" 'failed to deserialize parameters'
echo "OK: mapkit takes and returns typed maps, maps of objects and maps of maps with sorted keys and nested additionalProperties"
