#!/bin/sh
# L5 for integer arithmetic: Ruby rounding for / and %, Rust::Int32 as the explicit opt-in to
# truncation, and friendly errors (what, where, how to fix) for overflow and division by zero.
# usage: sh test/e2e_arith.sh [CRATE_DIR]      (default /tmp/arith-out)
set -eu
dir=${1:-/tmp/arith-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":{"a":%s,"b":%s}}}\n' "$1" "$2" "$3" "$4"; }
call1() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":{"a":%s}}}\n' "$1" "$2" "$3"; }

out=$( { printf '%s\n%s\n' "$init" "$inited"
         call 3 add 2 3
         call 4 add 2147483647 1
         call 5 multiply 65536 65536
         call 6 divide -7 2
         call 7 divide_like_rust -7 2
         call 8 modulo -7 3
         call 9 modulo 7 -3
         call 10 divide 1 0
         call 11 divide -2147483648 -1
         call1 12 negate -2147483648
         call 13 subtract -2147483648 1
         call 14 add 2147483646 1
         call 15 divide_like_rust 1 0
         call 16 divide 7 2
         call 17 divide -7 -2
         call 18 divide 7 -2
         call 19 modulo -7 -3
         call 20 modulo 6 3
         call1 21 negate 5
         call 22 remainder_like_rust -7 3
         call 23 remainder_like_rust 7 -3
         call 24 remainder_like_rust 5 0
         sleep 3; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-260

fail() { echo "FAIL: $1"; exit 1; }
has() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" || fail "id $1 should contain: $3"; }

printf '%s\n' "$out" | grep -q '"serverInfo":{"name":"arith","version":"0.1.0"}' || fail "serverInfo"
has 3 "$out" '"text":"5"'
has 14 "$out" '"text":"2147483647"'
# Ruby rounding (division rounds down, the sign of % follows the divisor)
has 6 "$out" '"text":"-4"'
has 8 "$out" '"text":"2"'
has 9 "$out" '"text":"-2"'
has 16 "$out" '"text":"3"'
has 17 "$out" '"text":"3"'
has 18 "$out" '"text":"-4"'
has 19 "$out" '"text":"-1"'
has 20 "$out" '"text":"0"'
has 21 "$out" '"text":"-5"'
# explicit opt-in to Rust semantics
has 7 "$out" '"text":"-3"'
# friendly overflow: what, where, how to fix
for id in 4 5 11 12 13; do
  has $id "$out" 'error: integer overflow at examples/arith.rb:'
  has $id "$out" 'does not fit in i32 (-2147483648..=2147483647)'
  has $id "$out" 'Fix:'
done
has 4 "$out" 'in tool `add`: 2147483647 + 1'
has 12 "$out" 'negating -2147483648 does not fit in i32'
has 5 "$out" 'in tool `multiply`: 65536 * 65536'
has 13 "$out" 'in tool `subtract`'
# friendly division by zero
has 10 "$out" 'error: division by zero at examples/arith.rb:'
has 10 "$out" 'Fix: check that the divisor is not zero'
has 15 "$out" 'error: division by zero at examples/arith.rb:'
has 15 "$out" 'in tool `divide_like_rust`'
has 22 "$out" '"text":"-1"'
has 23 "$out" '"text":"1"'
has 24 "$out" 'error: division by zero'
echo "OK: Ruby rounding by default, Rust::Int32 truncates, overflow and division by zero say what, where and how to fix"
