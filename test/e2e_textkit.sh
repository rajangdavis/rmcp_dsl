#!/bin/sh
# L5 end to end for the textkit server (slug, word_count, redact_digits).
# usage: sh test/e2e_textkit.sh [CRATE_DIR]      (default /tmp/textkit-out)
# Build the crate first:  ruby exe/rmcp_dsl examples/textkit.rb -o /tmp/textkit-out
set -eu
dir=${1:-/tmp/textkit-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
list='{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# call ID TOOL JSON_STRING_ARGUMENT
call() {
  printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":{"text":%s}}}\n' "$1" "$2" "$3"
}

out=$( { printf '%s\n%s\n%s\n' "$init" "$inited" "$list"
         call 3 slug '"  Hello, World! "'
         call 4 slug '"---Already--Slugged---"'
         call 5 slug '""'
         call 6 word_count '"  the quick  brown\tfox "'
         call 7 word_count '""'
         call 8 redact_digits '"call 555-1234 now"'
         call 9 title_case '"the quick  brown\tfox"'
         call 10 title_case '""'
         call 11 title_case '"éCOLE normale"'
         sleep 3; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out"

fail() { echo "FAIL: $1"; exit 1; }
printf '%s\n' "$out" | grep -q '"serverInfo":{"name":"textkit","version":"0.1.0"}' || fail "serverInfo is not textkit 0.1.0"
for t in slug word_count redact_digits title_case; do
  printf '%s\n' "$out" | grep -q "\"name\":\"$t\"" || fail "tools/list does not contain $t"
done

# expect ID TEXT: the reply with that id must carry exactly that text
expect() {
  printf '%s\n' "$out" | grep -q "\"id\":$1,\"result\":{\"content\":\[{\"type\":\"text\",\"text\":\"$2\"}\]" || fail "id $1 did not return '$2'"
}
expect 3 'hello-world'
expect 4 'already-slugged'
expect 5 ''
expect 6 '4'
expect 7 '0'
expect 8 'call ###-#### now'
expect 9 'The Quick Brown Fox'
expect 10 ''
expect 11 'École Normale'
echo "OK: textkit passes slug (3), word_count (2), redact_digits (1), title_case (3)"
