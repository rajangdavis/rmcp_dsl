#!/bin/sh
# L5 for webkit: the request guard and the HTML, URL and address bindings, with no network needed (IP
# literals and localhost only). A page fetch from the public internet is not tested here.
# usage: sh test/e2e_webkit.sh [CRATE_DIR]      (default /tmp/webkit-out)
set -eu
dir=${1:-/tmp/webkit-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$1" "$2" "$3"; }

out=$( { printf '%s\n%s\n' "$init" "$inited"
         call 10 check_url '{"url":"http://8.8.8.8/"}'
         call 11 check_url '{"url":"http://127.0.0.1:1/"}'
         call 12 check_url '{"url":"http://169.254.169.254/latest/meta-data/"}'
         call 13 check_url '{"url":"http://localhost/"}'
         call 14 check_url '{"url":"http://[::1]/"}'
         call 15 check_url '{"url":"http://2130706433/"}'
         call 16 check_url '{"url":"http://0x7f.0.0.1/"}'
         call 17 check_url '{"url":"file:///etc/passwd"}'
         call 18 check_url '{"url":"not a url"}'
         call 19 check_url '{"url":"http://user:pw@8.8.8.8/"}'
         call 20 check_url '{"url":"http://10.0.0.1/"}'
         call 21 fetch_page '{"url":"http://127.0.0.1:1/"}'
         call 22 fetch_page '{"url":"http://[::ffff:10.0.0.1]/"}'
         call 30 select_html '{"html":"<ul><li>a</li><li>b <b>c</b></li></ul>","css":"li"}'
         call 31 select_html '{"html":"<p>x</p>","css":"h1"}'
         call 32 select_html '{"html":"<p>x</p>","css":"p["}'
         call 33 attr_html '{"html":"<a href=\"/one\">1</a><a>2</a><a href=\"/two\">3</a>","css":"a","name":"href"}'
         call 34 attr_html '{"html":"<a href=\"/x\">y</a>","css":"a[","name":"href"}'
         call 35 selector_ok '{"css":"ul > li.item"}'
         call 36 selector_ok '{"css":"a["}'
         call 40 absolute '{"base":"https://example.com/a/b","href":"../q"}'
         call 41 absolute '{"base":"nope","href":"x"}'
         call 42 host_of '{"url":"https://Example.COM:8080/x"}'
         call 43 host_of '{"url":"not a url"}'
         call 44 is_public '{"ip":"8.8.8.8"}'
         call 45 is_public '{"ip":"10.0.0.1"}'
         call 46 is_public '{"ip":"::ffff:127.0.0.1"}'
         call 50 endpoint_of '{"url":"http://8.8.8.8/"}'
         sleep 6; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-210

fail() { echo "FAIL: $1"; exit 1; }
has() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" || fail "id $1 should contain: $3"; }
is() { has "$1" "$2" "\"text\":\"$3\"}],\"isError\":false"; }
bad() { has "$1" "$2" "\"isError\":true"; has "$1" "$2" "$3"; }

printf '%s\n' "$out" | grep -q '"serverInfo":{"name":"webkit","version":"0.1.0"}' || fail "serverInfo"
# The guard: only public addresses over http(s), no credentials; every way of writing loopback is caught.
is 10 "$out" 'ok: 8.8.8.8'
bad 11 "$out" 'blocked address for 127.0.0.1'
bad 12 "$out" 'blocked address for 169.254.169.254'
bad 13 "$out" 'blocked address for localhost'
bad 14 "$out" 'blocked address for ::1'
bad 15 "$out" 'blocked address for 127.0.0.1'
bad 16 "$out" 'blocked address for 127.0.0.1'
bad 17 "$out" 'only http and https are allowed, not file'
bad 18 "$out" 'not a valid URL'
bad 19 "$out" 'credentials in URLs are not supported'
bad 20 "$out" 'blocked address for 10.0.0.1'
bad 21 "$out" 'blocked address for 127.0.0.1'
bad 22 "$out" 'blocked address'
# Html: nil for a bad selector becomes an error or an empty result, depending on what the tool says.
is 30 "$out" 'a\nb c'
is 31 "$out" '(no matches)'
bad 32 "$out" 'invalid CSS selector: p['
is 33 "$out" '/one\n/two'
is 34 "$out" '(none)'
is 35 "$out" 'valid'
is 36 "$out" 'invalid'
# Url and Net
is 40 "$out" 'https://example.com/q'
is 41 "$out" '(invalid)'
is 42 "$out" 'example.com'
is 43 "$out" '(none)'
is 44 "$out" 'public'
is 45 "$out" 'not public'
is 46 "$out" 'not public'
is 50 "$out" 'https://8.8.8.8:80 http://8.8.8.8:80'
echo "OK: webkit guards requests with Ruby plus bindings, and reads HTML, URLs and addresses without any hand-written Rust"
