#!/bin/sh
# L5 for the language server: `rmcp_dsl lsp` as a real process over stdio with Content-Length framing, the way an
# editor talks to it. Diagnostics with suggestions, hover, inlay hints and completion on real example files.
# usage: sh test/e2e_lsp.sh        (from the repository root; needs ruby)
set -eu
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
root=$(pwd)

frame() { printf 'Content-Length: %s\r\n\r\n%s' "$(printf '%s' "$1" | wc -c | tr -d ' ')" "$1"; }
json() { ruby -rjson -e 'puts File.read(ARGV[0]).then { |t| ARGV[1] ? t.sub(ARGV[1], ARGV[2]) : t }.to_json' "$@"; }

broken_uri="file://$root/examples/statkit.rb"
good_uri="file://$root/examples/formkit.rb"
broken_text=$(json examples/statkit.rb 'i.upcase' 'i.upcas')
good_text=$(json examples/formkit.rb)

# 0-based line and column of `email` inside formkit's interpolation (ASCII line, so columns agree)
n=$(grep -n 'greeting} #{email}' examples/formkit.rb | head -1 | cut -d: -f1)
col=$(awk -v n="$n" 'NR == n { print index($0, "email") + 1 }' examples/formkit.rb)
line0=$((n - 1))

# definition from the type of `field :address, :Address` to `params :Address do` (ASCII lines, so columns agree)
dn=$(grep -n "field :address, :Address" examples/formkit.rb | head -1 | cut -d: -f1)
dcol=$(awk -v n="$dn" 'NR == n { print index($0, ":Address") + 1 }' examples/formkit.rb)
target0=$(($(grep -n "params :Address do" examples/formkit.rb | head -1 | cut -d: -f1) - 1))

# completion on a map: mapkit with its `scores.fetch(...)` line replaced by `scores.`, cut right after the dot (completion is
# not offered inside the string that line is in)
map_uri="file://$root/examples/mapkit.rb"
mn=$(grep -n "scores.fetch" examples/mapkit.rb | head -1 | cut -d: -f1)
map_line="      scores."
mcol=${#map_line}
map_text=$(ruby -rjson -e 'n = ARGV[1].to_i; ls = File.readlines(ARGV[0]); ls[n - 1] = ARGV[2] + "\n"; puts ls.join.to_json' examples/mapkit.rb "$mn" "$map_line")

{
  frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}'
  frame '{"jsonrpc":"2.0","method":"initialized","params":{}}'
  frame "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"$broken_uri\",\"languageId\":\"ruby\",\"version\":1,\"text\":$broken_text}}}"
  frame "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"$good_uri\",\"languageId\":\"ruby\",\"version\":1,\"text\":$good_text}}}"
  frame "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"$good_uri\"},\"position\":{\"line\":$line0,\"character\":$col}}}"
  frame "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/inlayHint\",\"params\":{\"textDocument\":{\"uri\":\"$good_uri\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":60,\"character\":0}}}}"
  frame '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/typing.rmcp.rb","languageId":"ruby","version":1,"text":"server \"x\", version: \"0.1.0\" do\n  \n"}}}'
  frame '{"jsonrpc":"2.0","id":4,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///tmp/typing.rmcp.rb"},"position":{"line":1,"character":2}}}'
  frame "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"$good_uri\"},\"position\":{\"line\":$((dn - 1)),\"character\":$dcol}}}"
  frame "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"$good_uri\"}}}"
  frame "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"$map_uri\",\"languageId\":\"ruby\",\"version\":1,\"text\":$map_text}}}"
  frame "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"$map_uri\"},\"position\":{\"line\":$((mn - 1)),\"character\":$mcol}}}"
  frame '{"jsonrpc":"2.0","id":5,"method":"shutdown"}'
  frame '{"jsonrpc":"2.0","method":"exit"}'
} > "$tmp/in"

ruby exe/rmcp_dsl lsp < "$tmp/in" > "$tmp/out"
tr -d '\r' < "$tmp/out" | grep -v '^Content-Length' | grep -v '^$' | cut -c1-220

fail() { echo "FAIL: $1"; exit 1; }
has() { tr -d '\r' < "$tmp/out" | grep -v '^Content-Length' | grep "$1" | grep -qF -- "$2" || fail "$1 should contain: $2"; }
has '"id":1,' '"hoverProvider":true'; has '"id":1,' '"inlayHintProvider"'; has '"id":1,' '"completionProvider"'
has 'publishDiagnostics' 'upcas'; has 'publishDiagnostics' '"suggestions":["upcase"]'; has 'publishDiagnostics' '"source":"rmcp_dsl"'
has '"id":2,' 'email: String'
has '"id":3,' '": String"'; has '"id":3,' '": T::Array[String]"'
has '"id":4,' '"label":"params"'; has '"id":4,' '"label":"tool"'
has '"id":5,' '"result":null'
has '"id":8,' '"label":"fetch"'; has '"id":8,' '"label":"keys"'
has '"id":6,' "\"range\":{\"start\":{\"line\":$target0,\"character\":10},\"end\":{\"line\":$target0,\"character\":17}}"
has '"id":7,' '"name":"formkit"'; has '"id":7,' '"name":"RegisterParams"'; has '"id":7,' '"name":"city"'
echo "OK: rmcp_dsl lsp answers diagnostics with suggestions, hover, inlay hints and completion over real stdio framing"
