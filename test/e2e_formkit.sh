#!/bin/sh
# L5 for formkit: list fields, a nested object, defaults and a format, over JSON-RPC.
# usage: sh test/e2e_formkit.sh [CRATE_DIR]      (default /tmp/formkit-out)
set -eu
dir=${1:-/tmp/formkit-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"register","arguments":%s}}\n' "$1" "$2"; }
sum() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"summarize","arguments":%s}}\n' "$1" "$2"; }
addr='"address":{"city":"Austin","zip":"78701"}'

out=$( { printf '%s\n%s\n' "$init" "$inited"
         printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
         call 3 "{\"email\":\"a@b.co\",\"tags\":[\"x\",\"y\"],\"scores\":[1,2,3],\"ratings\":[1.5,2.5],\"level\":4,\"greeting\":\"hi\",$addr,\"billing\":{\"city\":\"Dallas\",\"zip\":\"75001\"}}"
         call 4 "{\"email\":\"a@b.co\",\"tags\":[\"x\"],\"scores\":[],$addr}"
         call 5 "{\"email\":\"a@b.co\",\"tags\":[],\"scores\":[1],$addr}"
         call 6 "{\"email\":\"a@b.co\",\"tags\":[\"a\",\"b\",\"c\",\"d\"],\"scores\":[1],$addr}"
         call 7 '{"email":"a@b.co","tags":["x"],"scores":[1],"address":{"city":"Austin","zip":"abc"}}'
         call 8 "{\"email\":\"a@b.co\",\"tags\":[\"x\"],\"scores\":[1],\"level\":9,$addr}"
         call 9 '{"email":"a@b.co","tags":["x"],"scores":[1]}'
         call 10 "{\"email\":\"a@b.co\",\"tags\":[\"x\"],\"scores\":[1],\"quantity\":10,$addr}"
         call 11 "{\"email\":\"a@b.co\",\"tags\":[\"x\"],\"scores\":[1],\"quantity\":0,$addr}"
         call 12 "{\"email\":\"a@b.co\",\"tags\":[\"x\"],\"scores\":[1],\"quantity\":3,$addr}"
         call 13 "{\"email\":\"a@b.co\",\"tags\":[\"x\"],\"scores\":[1],\"quantity\":50,$addr}"
         call 14 "{\"email\":\"a@b.co\",\"tags\":[\"x\"],\"scores\":[1],\"ratings\":[1.0,2.0,3.0,4.0,5.0],$addr}"
         call 15 "{\"email\":\"a@b.co\",\"tags\":[\"x\"],\"scores\":[1],\"ratings\":[],$addr}"
         call 16 "{\"email\":\"a@b.co\",\"tags\":[\"x\"],\"scores\":[1],$addr,\"offices\":[{\"city\":\"Reno\",\"zip\":\"89501\"},{\"city\":\"Boise\",\"zip\":\"83701\"}]}"
         call 17 "{\"email\":\"a@b.co\",\"tags\":[\"x\"],\"scores\":[1],$addr,\"offices\":[{\"city\":\"Reno\",\"zip\":\"abc\"}]}"
         call 18 "{\"email\":\"a@b.co\",\"tags\":[\"x\"],\"scores\":[1],$addr,\"offices\":[]}"
         call 19 "{\"email\":\"a@b.co\",\"tags\":[\"x\"],\"scores\":[1],$addr,\"offices\":[{\"city\":\"A\",\"zip\":\"1\"},{\"city\":\"B\",\"zip\":\"2\"},{\"city\":\"C\",\"zip\":\"3\"},{\"city\":\"D\",\"zip\":\"4\"}]}"
         sum 20 "{\"offices\":[{\"city\":\"Reno\",\"zip\":\"89501\"},{\"city\":\"Boise\",\"zip\":\"83701\"}]}"
         sleep 3; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-240

fail() { echo "FAIL: $1"; exit 1; }
has() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" || fail "id $1 should contain: $3"; }
has 2 "$out" '"format":"email"'; has 2 "$out" '"minItems":1'; has 2 "$out" '"maxItems":3'
has 2 "$out" '"default":1'; has 2 "$out" '"default":"hello"'; has 2 "$out" '"address"'
has 2 "$out" '"billing"'; has 2 "$out" '"maxItems":4'
has 2 "$out" '"exclusiveMinimum":0'; has 2 "$out" '"exclusiveMaximum":50'; has 2 "$out" '"multipleOf":5'
has 3 "$out" 'hi a@b.co: level 4, quantity 5, tags x+y, total 6, ratings 1.5,2.5, Austin 78701, billed 75001'
has 4 "$out" 'hello a@b.co: level 1, quantity 5, tags x, total 0, ratings none, Austin 78701, billed same'
has 10 "$out" 'hello a@b.co: level 1, quantity 10, tags x, total 1, ratings none, Austin 78701, billed same'
for id in 5 6 7 8 11 12 13 14 15; do has $id "$out" '"isError":true'; done
has 5 "$out" 'tags'; has 6 "$out" 'tags'; has 7 "$out" 'zip'; has 8 "$out" 'level'
has 9 "$out" 'missing field `address`'
has 11 "$out" 'exclusive minimum'; has 12 "$out" 'multiple of'; has 13 "$out" 'exclusive maximum'
has 14 "$out" 'maximum of 4'; has 15 "$out" 'minimum of 1'
has 16 "$out" 'offices Reno:89501,Boise:83701'
for id in 17 18 19; do has $id "$out" '"isError":true'; done
has 17 "$out" 'zip'; has 18 "$out" 'minimum of 1'; has 19 "$out" 'maximum of 3'
has 20 "$out" '2/2 empty=false first=Reno last=83701 picked=Boise found=Reno any=true all=true count=2 kept=Boise|Reno dropped='
printf '%s\n' "$out" | ruby -rjson -e '
  text = STDIN.read
  line = text.lines.find { |l| l.include?(%q{"id":2,}) } or abort "no tools/list response"
  schema = JSON.parse(line).dig("result", "tools", 0, "inputSchema")
  req = schema["required"] || []
  abort "billing must not be required" if req.include?("billing")
  abort "address must be required" unless req.include?("address")
  prop = schema.dig("properties", "ratings")
  items = prop["items"] || Array(prop["anyOf"]).filter_map { |s| s["items"] }.first
  abort "ratings must be an array of numbers" unless items && items["type"] == "number"
  off = schema.dig("properties", "offices")
  arr = off && (off["items"] ? off : Array(off["anyOf"]).find { |s| s["items"] })
  abort "offices must be an optional array" unless arr
  abort "offices must not be required" if req.include?("offices")
  abort "offices needs minItems 1 and maxItems 3" unless arr["minItems"] == 1 && arr["maxItems"] == 3
  oitems = arr["items"]
  defs = schema["$defs"] || {}
  resolved = oitems && oitems["$ref"] ? defs[oitems["$ref"].split("/").last] : oitems
  abort "offices must be an array of Address objects" unless resolved && resolved["type"] == "object" && resolved.dig("properties", "city") && resolved.dig("properties", "zip")
  office_args = [{ "city" => "Reno", "zip" => "89501" }, { "city" => "Boise", "zip" => "83701" }]
  expected = "hello a@b.co: level 1, quantity 5, tags x, total 1, ratings none, Austin 78701, billed same, offices " + office_args.map { |o| "#{o["city"]}:#{o["zip"]}" }.join(",")
  abort "the office result must match Ruby: #{expected}" unless text.include?(expected)
' || fail "inputSchema shape"
echo "OK: formkit takes lists of strings, integers and floats, required and optional nested objects, defaults and formats, and enforces their limits"
