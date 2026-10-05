#!/bin/sh
# L5 for webpeek, hermetic: a local fixture server (test/fixture_server.rb) plays the web.
# webpeek has no address guard, so it reaches the fixture's loopback address directly.
# Checks the success paths, that every failure is an error result (isError true) whose text starts
# with "error:", and that the tool schema carries the field description.
# usage: sh test/e2e_webpeek.sh [CRATE_DIR]      (default /tmp/webpeek-out; about 30 s; needs ruby, curl)
set -eu
dir=${1:-/tmp/webpeek-out}
here=$(cd "$(dirname "$0")" && pwd)

portfile=$(mktemp)
ruby "$here/fixture_server.rb" > "$portfile" &
fixture=$!
trap 'kill "$fixture" 2>/dev/null || true; rm -f "$portfile"' EXIT INT TERM
tries=0
until grep -q '^PORT ' "$portfile"; do
  tries=$((tries + 1))
  [ "$tries" -le 50 ] || { echo "FAIL: the fixture server did not start"; exit 1; }
  sleep 0.2
done
port=$(sed -n 's/^PORT //p' "$portfile")
base="http://127.0.0.1:$port"

init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
list='{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":{"url":"%s"}}}\n' "$1" "$2" "$3"; }

fail() { echo "FAIL: $1"; exit 1; }
# Use printf, not echo: macOS sh echo turns the JSON \n escapes into real newlines.
# has ID OUTPUT NEEDLE: the reply with that id contains NEEDLE
has() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" || fail "id $1 should contain: $3"; }
# lacks ID OUTPUT NEEDLE
lacks() { if printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3"; then fail "id $1 should not contain: $3"; fi; }
# failed ID OUTPUT: an error result whose text starts with "error:"
failed() { has "$1" "$2" '"text":"error:'; has "$1" "$2" '"isError":true'; }
# ok ID OUTPUT: a success result
ok() { has "$1" "$2" '"isError":false'; }

out=$( { printf '%s\n%s\n%s\n' "$init" "$inited" "$list"
         call 10 fetch "$base/"
         call 11 head "$base/"
         call 12 text "$base/page"
         call 13 title "$base/page"
         call 14 title "$base/"
         call 15 word_count "$base/"
         call 16 fetch "$base/404"
         call 17 fetch "$base/redir"
         call 18 fetch "$base/loop1"
         call 19 fetch "http://127.0.0.1:1/"
         call 20 fetch "file:///etc/passwd"
         call 21 title "http://127.0.0.1:1/"
         call 22 word_count "http://127.0.0.1:1/"
         call 23 text "http://127.0.0.1:1/"
         call 24 fetch "$base/big"
         call 25 fetch "$base/slow"
         call 26 head "$base/404"
         sleep 22; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-200

printf '%s\n' "$out" | grep -q '"serverInfo":{"name":"webpeek","version":"0.1.0"}' || fail "serverInfo"
has 2 "$out" 'Absolute http or https URL'
for t in fetch head text title word_count; do has 2 "$out" "\"name\":\"$t\""; done

has 10 "$out" 'fixture page';         ok 10 "$out"
has 11 "$out" 'HTTP/1.1 200';         has 11 "$out" 'Content-Type: text/html'; lacks 11 "$out" 'fixture page'; ok 11 "$out"
has 12 "$out" 'Main heading';         lacks 12 "$out" '<h1>'; ok 12 "$out"
has 13 "$out" '"text":"Fixture title"'; ok 13 "$out"
has 14 "$out" '(no title)';           ok 14 "$out"
has 15 "$out" '"text":"2"';           ok 15 "$out"
failed 16 "$out"; has 16 "$out" '404'
has 17 "$out" 'fixture page';         ok 17 "$out"
failed 18 "$out"
failed 19 "$out"
failed 20 "$out"; lacks 20 "$out" 'root:'
failed 21 "$out"; lacks 21 "$out" '(no title)'
failed 22 "$out"
failed 23 "$out"
failed 24 "$out"
failed 25 "$out"
failed 26 "$out"
echo "OK: webpeek reads pages, titles and word counts, and reports every failure as an error result"
