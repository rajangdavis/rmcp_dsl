#!/bin/sh
# L5 for fetchkit, hermetic: a local fixture server (test/fixture_server.rb) plays the web.
# Run A allows the fixture's loopback address and checks success and failure paths.
# Run B allows nothing and checks that loopback and private ranges are refused.
# usage: sh test/e2e_fetchkit.sh [CRATE_DIR]      (default /tmp/fetchkit-out; about 40 s; needs ruby, curl)
set -eu
dir=${1:-/tmp/fetchkit-out}
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
port6=$(sed -n 's/^PORT6 //p' "$portfile")   # empty when this machine has no IPv6 loopback
base="http://127.0.0.1:$port"

init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":{"url":"%s"}}}\n' "$1" "$2" "$3"; }
call2() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":{"url":"%s","css":"%s"}}}\n' "$1" "$2" "$3" "$4"; }
call3() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":{"url":"%s","css":"%s","attr":"%s"}}}\n' "$1" "$2" "$3" "$4" "$5"; }
serve() { (cd "$dir" && FETCHKIT_ALLOW_HOSTS="$1" cargo run -q); }

fail() { echo "FAIL: $1"; exit 1; }
# Use printf, not echo: macOS sh echo turns the JSON \n escapes into real newlines.
# has ID OUTPUT NEEDLE: the reply with that id contains NEEDLE
has() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" || fail "id $1 should contain: $3"; }
# lacks ID OUTPUT NEEDLE
lacks() { if printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3"; then fail "id $1 should not contain: $3"; fi; }
# refused ID OUTPUT: some error came back and the fixture page did not
refused() { has "$1" "$2" 'error:'; lacks "$1" "$2" 'fixture page'; }

echo "== run A: fixture host allowed"
outA=$( { printf '%s\n%s\n' "$init" "$inited"
          call 10 fetch "$base/"
          call 11 head "$base/"
          call 12 fetch "$base/404"
          call 13 fetch "$base/redir"
          call 14 fetch "$base/loop1"
          call 15 fetch "$base/meta"
          call 16 fetch "$base/bytes"
          call 17 fetch "$base/big"
          call 18 fetch "$base/slow"
          call 19 fetch "http://127.0.0.1:1/"
          call 20 fetch "file:///etc/passwd"
          call 21 fetch "ftp://example.com/"
          call 22 fetch "http://user:pw@example.com/"
          call 23 fetch "not a url"
          call 24 fetch ""
          call 25 fetch "http://"
          call 26 fetch "http://nonexistent.invalid/"
          call 27 fetch "$base/noloc"
          call2 40 select "$base/page" "h1"
          call2 41 select "$base/page" ".item"
          call2 42 select "$base/page" "p#x"
          call3 43 attr "$base/page" "a" "href"
          call2 44 select "$base/page" ".nope"
          call2 45 select "$base/page" "a["
          call2 46 select "$base/404" "p"
          if [ -n "$port6" ]; then call 28 fetch "http://[::1]:$port6/"; fi
          sleep 25; } | serve 127.0.0.1,::1 )
printf '%s\n' "$outA" | cut -c1-200

has 10 "$outA" 'fixture page';            has 10 "$outA" 'untrusted web content'; has 10 "$outA" 'HTTP 200'
has 11 "$outA" 'Content-Type: text/html'; lacks 11 "$outA" 'fixture page'
has 12 "$outA" 'error: HTTP 404'
has 13 "$outA" 'fixture page'
has 14 "$outA" 'more than 3 redirects'
has 15 "$outA" 'blocked address 169.254.169.254'
has 16 "$outA" 'ok '
has 17 "$outA" '(63)'
has 18 "$outA" '(28)'
has 19 "$outA" '(7)'
has 20 "$outA" 'unsupported scheme file'
has 21 "$outA" 'unsupported scheme ftp'
has 22 "$outA" 'credentials'
has 23 "$outA" 'not an absolute URL'
has 24 "$outA" 'empty URL'
has 25 "$outA" 'no host'
has 26 "$outA" 'cannot resolve'
has 27 "$outA" 'without a Location header'
if [ -n "$port6" ]; then has 28 "$outA" 'fixture page'; else echo "(no IPv6 loopback here: skipping the [::1] case)"; fi
has 40 "$outA" 'Main heading'; has 40 "$outA" '1 match(es)'; has 40 "$outA" 'untrusted web content'
has 41 "$outA" '3 match(es)';  has 41 "$outA" 'Three bold'
has 42 "$outA" 'Hello & goodbye'
has 43 "$outA" '/one';         has 43 "$outA" 'https://example.org/two'
has 44 "$outA" '(no matches)'
has 45 "$outA" 'invalid CSS selector'
has 46 "$outA" 'error: HTTP 404'
echo "run A ok"

echo "== run B: nothing allowed"
outB=$( { printf '%s\n%s\n' "$init" "$inited"
          call 30 fetch "$base/"
          call 31 fetch "http://localhost:$port/"
          call 32 fetch "http://10.0.0.1/"
          call 33 fetch "http://192.168.1.1/"
          call 34 fetch "http://169.254.169.254/latest/meta-data/"
          call 35 fetch "http://2130706433/"
          call 36 fetch "http://0x7f.0.0.1/"
          call 37 fetch "http://[::1]/"
          call2 38 select "http://10.0.0.1/" "p"
          call3 39 attr "http://169.254.169.254/" "a" "href"
          sleep 8; } | serve "" )
printf '%s\n' "$outB" | cut -c1-200

has 30 "$outB" 'blocked address 127.0.0.1'; lacks 30 "$outB" 'fixture page'
has 31 "$outB" 'blocked address'; lacks 31 "$outB" 'fixture page'
has 32 "$outB" 'blocked address 10.0.0.1'
has 33 "$outB" 'blocked address 192.168.1.1'
has 34 "$outB" 'blocked address 169.254.169.254'
refused 35 "$outB"
refused 36 "$outB"
has 37 "$outB" 'blocked address ::1'
has 38 "$outB" 'blocked address 10.0.0.1'
has 39 "$outB" 'blocked address 169.254.169.254'
echo "OK: fetchkit succeeds on public pages and refuses or reports every failure path"
