#!/bin/sh
# L5 for notekit: annotations and constraints reach tools/list, optional fields may be left out or null,
# and a value that breaks a constraint comes back as an error result (the server enforces them).
# usage: sh test/e2e_notekit.sh [CRATE_DIR]      (default /tmp/notekit-out)
set -eu
dir=${1:-/tmp/notekit-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
list='{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
rpc() { printf '{"jsonrpc":"2.0","id":%s,"method":"%s","params":%s}\n' "$1" "$2" "$3"; }
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$1" "$2" "$3"; }

out=$( { printf '%s\n%s\n%s\n' "$init" "$inited" "$list"
         call 10 search '{"query":"cats"}'
         call 11 search '{"query":"cats","limit":5,"kind":"recent","tag":"a-b","weight":2.0,"exact":true}'
         call 12 search '{"query":""}'
         call 13 search '{"query":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
         call 14 search '{"query":"x","limit":0}'
         call 15 search '{"query":"x","limit":100}'
         call 16 search '{"query":"x","kind":"bogus"}'
         call 17 search '{"query":"x","tag":"Bad Tag"}'
         call 18 search '{"query":"x","weight":0.1}'
         call 19 delete_note '{"id":3}'
         call 20 delete_note '{"id":0}'
         call 21 search '{"query":"x","limit":null}'
         printf '%s\n' '{"jsonrpc":"2.0","id":50,"method":"prompts/list"}'
         rpc 51 prompts/get '{"name":"summarize","arguments":{"topic":"cats"}}'
         rpc 52 prompts/get '{"name":"summarize","arguments":{"topic":"cats","style":"detailed"}}'
         rpc 53 prompts/get '{"name":"summarize","arguments":{"topic":"cats","style":"bogus"}}'
         rpc 54 prompts/get '{"name":"summarize","arguments":{"topic":""}}'
         printf '%s\n' '{"jsonrpc":"2.0","id":55,"method":"resources/list"}'
         rpc 56 resources/read '{"uri":"notekit://guide"}'
         rpc 57 resources/read '{"uri":"notekit://missing"}'
         rpc 58 completion/complete '{"ref":{"type":"ref/prompt","name":"summarize"},"argument":{"name":"style","value":""}}'
         rpc 59 completion/complete '{"ref":{"type":"ref/prompt","name":"summarize"},"argument":{"name":"style","value":"d"}}'
         rpc 60 completion/complete '{"ref":{"type":"ref/prompt","name":"summarize"},"argument":{"name":"style","value":"x"}}'
         rpc 61 completion/complete '{"ref":{"type":"ref/prompt","name":"summarize"},"argument":{"name":"topic","value":"c"}}'
         rpc 62 completion/complete '{"ref":{"type":"ref/prompt","name":"nope"},"argument":{"name":"style","value":""}}'
         rpc 63 completion/complete '{"ref":{"type":"ref/prompt","name":"summarize"},"argument":{"name":"zzz","value":""}}'
         printf '%s\n' '{"jsonrpc":"2.0","id":70,"method":"resources/templates/list"}'
         rpc 71 resources/read '{"uri":"notekit://notes/42"}'
         rpc 72 resources/read '{"uri":"notekit://notes/404"}'
         rpc 73 resources/read '{"uri":"notekit://notes/abc"}'
         rpc 74 resources/read '{"uri":"notekit://notes/%34%32"}'
         rpc 75 resources/read '{"uri":"notekit://notes/%zz"}'
         rpc 76 resources/read '{"uri":"notekit://notes/"}'
         rpc 77 resources/read '{"uri":"notekit://notes/1/2"}'
         rpc 78 resources/read '{"uri":"notekit://lists/pinned"}'
         rpc 79 resources/read '{"uri":"notekit://lists/bogus"}'
         rpc 80 completion/complete '{"ref":{"type":"ref/resource","uri":"notekit://lists/{kind}"},"argument":{"name":"kind","value":"p"}}'
         rpc 81 completion/complete '{"ref":{"type":"ref/resource","uri":"notekit://notes/{id}"},"argument":{"name":"id","value":"4"}}'
         rpc 82 completion/complete '{"ref":{"type":"ref/resource","uri":"notekit://nope/{x}"},"argument":{"name":"x","value":""}}'
         rpc 83 completion/complete '{"ref":{"type":"ref/resource","uri":"notekit://lists/{kind}"},"argument":{"name":"zzz","value":""}}'
         sleep 4; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-220

fail() { echo "FAIL: $1"; exit 1; }
has() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" || fail "id $1 should contain: $3"; }
is() { has "$1" "$2" "\"text\":\"$3\"}],\"isError\":false"; }
bad() { has "$1" "$2" "\"isError\":true"; has "$1" "$2" "$3"; }

printf '%s\n' "$out" | grep -q '"serverInfo":{"name":"notekit","version":"0.1.0"}' || fail "serverInfo"
has 1 "$out" '"instructions":"Search the notes with `search`'
# What a client sees: annotations, schema constraints, and only `query` required.
has 2 "$out" '"readOnlyHint":true';   has 2 "$out" '"openWorldHint":false'; has 2 "$out" 'Search notes'
has 2 "$out" '"destructiveHint":true'; has 2 "$out" '"idempotentHint":true'
has 2 "$out" '"icons":[{"src":"https://example.com/search.png"'
has 2 "$out" '"minLength":1';          has 2 "$out" '"maxLength":40'
has 2 "$out" '"minimum":1';            has 2 "$out" '"maximum":50'
has 2 "$out" '"enum":["all","recent","pinned"]'
has 2 "$out" '"pattern":"^[a-z][a-z0-9-]*$"'
has 2 "$out" '"required":["query"]'

is 10 "$out" 'cats|10|all|-|normal|false'
is 11 "$out" 'cats|5|recent|a-b|heavy|true'
bad 12 "$out" 'fewer than the minimum of 1'
bad 13 "$out" 'more than the maximum of 40'
bad 14 "$out" 'is below the minimum of 1'
bad 15 "$out" 'is above the maximum of 50'
bad 16 "$out" 'is not one of all, recent, pinned'
bad 17 "$out" 'does not match the pattern'
bad 18 "$out" 'is below the minimum of 0.5'
is 19 "$out" 'deleted 3'
bad 20 "$out" 'is below the minimum of 1'
is 21 "$out" 'x|10|all|-|normal|false'
# Capabilities, prompts and resources
has 1 "$out" '"prompts"';  has 1 "$out" '"resources"';  has 1 "$out" '"tools"'
has 50 "$out" '"name":"summarize"'; has 50 "$out" '"name":"topic"'; has 50 "$out" '"required":true'
has 51 "$out" 'Summarize my notes about cats in a short style.'
has 52 "$out" 'Summarize my notes about cats in a detailed style.'
has 53 "$out" '"error"'; has 53 "$out" 'is not one of short, detailed'
has 54 "$out" '"error"'; has 54 "$out" 'fewer than the minimum of 1'
has 55 "$out" '"uri":"notekit://guide"'; has 55 "$out" '"mimeType":"text/markdown"'; has 55 "$out" 'Notekit guide'
has 56 "$out" '# Notekit'; has 56 "$out" '"mimeType":"text/markdown"'
has 57 "$out" '"error"'; has 57 "$out" '"code":-32002'; has 57 "$out" '"data":{"uri":"notekit://missing"}'
has 1 "$out" '"completions":{}'
has 58 "$out" '"values":["short","detailed"]'; has 58 "$out" '"total":2'; has 58 "$out" '"hasMore":false'
has 59 "$out" '"values":["detailed"]'
has 60 "$out" '"values":[]'
has 61 "$out" '"values":[]'
has 62 "$out" '"code":-32602'; has 62 "$out" 'unknown prompt `nope`'
has 63 "$out" '"code":-32602'; has 63 "$out" 'prompt `summarize` has no argument `zzz`'
# Resource templates (MCP resources/templates/list, resources/read, completion/complete with ref/resource)
lacks() { if printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3"; then fail "id $1 should not contain: $3"; fi; }
has 70 "$out" '"resourceTemplates":['; has 70 "$out" '"uriTemplate":"notekit://notes/{id}"'; has 70 "$out" '"name":"note"'
has 70 "$out" '"title":"A note"'; has 70 "$out" '"mimeType":"text/plain"'; has 70 "$out" '"uriTemplate":"notekit://lists/{kind}"'
lacks 55 "$out" 'notes/{id}'
has 71 "$out" '"uri":"notekit://notes/42"'; has 71 "$out" '"text":"Note 42: remember the milk"'; has 71 "$out" '"mimeType":"text/plain"'
has 72 "$out" '"code":-32002'; has 72 "$out" 'no note with id 404'; has 72 "$out" '"data":{"uri":"notekit://notes/404"}'
has 73 "$out" '"code":-32602'; has 73 "$out" 'invalid value for id'; has 73 "$out" 'does not match the pattern'
has 74 "$out" '"uri":"notekit://notes/%34%32"'; has 74 "$out" '"text":"Note 42: remember the milk"'
has 75 "$out" '"code":-32602'; has 75 "$out" 'invalid percent-encoding in `{id}`'
has 76 "$out" '"code":-32602'; has 76 "$out" 'invalid value for id'
has 77 "$out" '"code":-32002'; has 77 "$out" '"data":{"uri":"notekit://notes/1/2"}'
has 78 "$out" '"text":"The pinned notes"'
has 79 "$out" '"code":-32602'; has 79 "$out" 'is not one of recent, pinned'
has 80 "$out" '"values":["pinned"]'; has 80 "$out" '"total":1'; has 80 "$out" '"hasMore":false'
has 81 "$out" '"values":[]'
has 82 "$out" '"code":-32602'; has 82 "$out" 'unknown resource template `notekit://nope/{x}`'
has 83 "$out" '"code":-32602'; has 83 "$out" 'resource template `notekit://lists/{kind}` has no argument `zzz`'
# _meta: a static JSON literal on a tool, a prompt, a static resource and a resource template (keys come back sorted)
has 2 "$out" '"_meta":{"com.example/limits":{"burst":5,"calls":100},"com.example/tier":"free"}'
has 50 "$out" '"_meta":{"com.example/audience":["students","editors"]}'
has 55 "$out" '"_meta":{"com.example.mcp/not-reserved":"ok","com.example/maintained":true}'
# the size of the guide (the compiler checked it against the body: 47 bytes)
has 55 "$out" '"size":47'
has 70 "$out" '"_meta":{"com.example/ttl":60}'
echo "OK: notekit advertises annotations and constraints, accepts omitted optional fields, and enforces every constraint"
