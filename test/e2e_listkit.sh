#!/bin/sh
# L5 for listkit: the answers below are what Ruby itself returns for the same calls (split drops
# trailing empty pieces, negative indexes count from the end, index counts characters, ...).
# usage: sh test/e2e_listkit.sh [CRATE_DIR]      (default /tmp/listkit-out)
set -eu
dir=${1:-/tmp/listkit-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
callt() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":{"text":"%s"}}}\n' "$1" "$2" "$3"; }
callsl() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":{"text":"%s","start":%s,"len":%s}}}\n' "$1" "$2" "$3" "$4" "$5"; }
callc() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":{"n":%s}}}\n' "$1" "$2" "$3"; }
calln() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":{"text":"%s","n":%s}}}\n' "$1" "$2" "$3" "$4"; }

out=$( { printf '%s\n%s\n' "$init" "$inited"
         callt 10 parts "a,b,,c,,"
         callt 11 parts ",a"
         callt 12 parts ""
         calln 20 nth "a,b,c" 1
         calln 21 nth "a,b,c" -1
         calln 22 nth "a,b,c" 5
         calln 23 nth "a,b,c" -4
         calln 24 nth "a,b,c" 0
         callt 30 last_part "x,y,"
         callt 31 last_part ""
         callt 40 first_or_raise "p,q"
         callt 41 first_or_raise ""
         callt 50 offset "hello"
         callt 51 offset "xyz"
         callt 52 offset "héllo"
         callt 60 kind "a"
         callt 61 kind "b"
         callt 62 kind "xylophone"
         callt 63 kind "zzz"
         callt 70 scrub "aab-bcc"
         callt 71 scrub "é-é"
         callt 72 scrub ""
         callt 80 member "red"
         callt 81 member "blue"
         callt 90 count ""
         callt 91 count "a,b"
         callt 92 count "a,b,,"
         callt 100 long_words "a quick brown fox"
         callt 101 short_words "a quick brown fox"
         callt 102 first_long "a quick brown fox"
         callt 103 first_long "a bc"
         callt 104 has_digit "ab c1"
         callt 105 has_digit "ab cd"
         callt 106 all_caps "AB CD"
         callt 107 all_caps "AB cd"
         callt 108 all_caps ""
         callt 109 how_many "apple avocado banana"
         callt 110 sorted "pear apple fig"
         callt 111 unique "a,b,a,c,b"
         callt 112 backwards "one two three"
         callt 120 port "8080"
         callt 121 port "  42abc"
         callt 122 port "1_000"
         callt 123 port "x"
         callt 124 port "-7"
         callt 125 bump "41"
         callt 126 port "99999999999999999999"
         callt 130 after_scheme "https://example.com/x"
         callt 131 after_scheme "nosep"
         callt 132 before_slash "a/b/c"
         callt 133 before_slash "abc"
         callt 134 limit_two "a,b,c"
         callt 135 limit_two "abc"
         callt 136 limit_two ""
         callt 140 strict "  42  "
         callt 141 strict "1_000"
         callt 142 strict "0x1A"
         callt 143 strict ""
         callt 144 strict "12abc"
         calln 150 repeat "ab" 3
         calln 151 repeat "ab" 0
         calln 152 repeat "ab" -1
         callt 160 pieces "héy"
         callt 161 pieces ""
         callt 170 line_count "a\\nb\\n"
         callt 171 line_count ""
         callt 172 line_count "a\\n\\n"
         callt 173 line_count "x"
         callsl 180 slice "hello" 1 3
         callsl 181 slice "hello" -3 2
         callsl 182 slice "hello" 5 1
         callsl 183 slice "hello" 6 1
         callsl 184 slice "héllo" 1 2
         callsl 185 slice "hello" 1 -1
         callsl 186 slice "hello" 3 100
         calln 190 at_char "abc" 0
         calln 191 at_char "abc" -1
         calln 192 at_char "abc" 3
         calln 193 at_char "héy" 1
         callt 200 bracket_digits "a1b22c"
         callt 201 bracket_digits ""
         callt 202 shout_first "hello world"
         callt 203 shout_first "123"
         callt 204 pad_empty "abc"
         callt 205 pad_empty ""
         callc 210 squares 5
         callc 211 squares 0
         callc 212 squares -1
         callc 213 total 10
         callc 214 total 0
         callc 215 evens 7
         callc 216 evens 1
         callc 217 biggest 3
         callc 218 biggest 0
         callt 219 digit_sum "1a2"
         callt 220 digit_sum ""
         callc 221 table 3
         callc 222 table 0
         callc 223 run_up 5
         callc 224 run_up 1
         callc 225 has_num 2
         callc 226 has_num 5
         callc 227 sorted_nums 0
         callc 228 guarded 3
         callc 229 guarded 5
         callc 230 first_big 10
         callc 231 first_big 3
         callc 232 count_even 10
         callc 233 all_small 4
         callc 234 all_small 5
         callt 235 twice "a,bb,ccc"
         callt 240 classify ""
         callt 241 classify "abcdef"
         callt 242 classify "ab1"
         callt 243 classify "abc"
         callt 244 classify "xyz"
         callc 245 big_or_list 3
         callc 246 big_or_list 5
         sleep 4; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-200

fail() { echo "FAIL: $1"; exit 1; }
has() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" || fail "id $1 should contain: $3"; }
is() { has "$1" "$2" "\"text\":\"$3\"}],\"isError\":false"; }

printf '%s\n' "$out" | grep -q '"serverInfo":{"name":"listkit","version":"0.1.0"}' || fail "serverInfo"
is 10 "$out" 'a|b||c'
is 11 "$out" '|a'
is 12 "$out" ''
is 20 "$out" 'b'
is 21 "$out" 'c'
is 22 "$out" '(none)'
is 23 "$out" '(none)'
is 24 "$out" 'a'
is 30 "$out" 'y'
is 31 "$out" '(none)'
is 40 "$out" 'p'
has 41 "$out" '"text":"empty"'; has 41 "$out" '"isError":true'
is 50 "$out" 'at 2'
is 51 "$out" 'none'
is 52 "$out" 'at 2'
is 60 "$out" 'ab'
is 61 "$out" 'ab'
is 62 "$out" 'x-word'
is 63 "$out" 'other'
is 70 "$out" 'xyz'
is 71 "$out" 'é'
is 72 "$out" ''
is 80 "$out" 'known'
is 81 "$out" 'unknown'
is 90 "$out" 'empty'
is 91 "$out" '2'
is 92 "$out" '2'
is 100 "$out" "quick,brown"
is 101 "$out" "a,fox"
is 102 "$out" "quick"
is 103 "$out" "(none)"
is 104 "$out" "yes"
is 105 "$out" "no"
is 106 "$out" "yes"
is 107 "$out" "no"
is 108 "$out" "yes"
is 109 "$out" "2"
is 110 "$out" "apple,fig,pear"
is 111 "$out" "a,b,c"
is 112 "$out" "three two one"
is 120 "$out" "8080"
is 121 "$out" "42"
is 122 "$out" "1000"
is 123 "$out" "0"
is 124 "$out" "-7"
is 125 "$out" "42"
has 126 "$out" "\"isError\":true"; has 126 "$out" "error: integer overflow at examples/listkit.rb"; has 126 "$out" "does not fit in i64"
is 130 "$out" "example.com/x"
is 131 "$out" ""
is 132 "$out" "a"
is 133 "$out" "abc"
is 134 "$out" "b,c"
is 135 "$out" "abc"
is 136 "$out" "(none)"
is 140 "$out" "42"
is 141 "$out" "1000"
for id in 142 143 144; do has $id "$out" "\"isError\":true"; has $id "$out" "error: invalid value for Integer()"; done
is 150 "$out" "ababab"
is 151 "$out" ""
has 152 "$out" "\"isError\":true"; has 152 "$out" "error: negative argument at examples/listkit.rb"
is 160 "$out" "h-é-y"
is 161 "$out" ""
is 170 "$out" "2"
is 171 "$out" "0"
is 172 "$out" "2"
is 173 "$out" "1"
is 180 "$out" "ell"
is 181 "$out" "ll"
is 182 "$out" ""
is 183 "$out" "(nil)"
is 184 "$out" "él"
is 185 "$out" "(nil)"
is 186 "$out" "lo"
is 190 "$out" "a"
is 191 "$out" "c"
is 192 "$out" "(nil)"
is 193 "$out" "é"
is 200 "$out" "a[1]b[22]c"
is 201 "$out" ""
is 202 "$out" "HELLO world"
is 203 "$out" "123"
is 204 "$out" "<>a<>b<>c<>"
is 205 "$out" "<>"
is 210 "$out" "0,1,4,9,16"
is 211 "$out" ""
is 212 "$out" ""
is 213 "$out" "55"
is 214 "$out" "0"
is 215 "$out" "2,4,6"
is 216 "$out" ""
is 217 "$out" "3"
is 218 "$out" ""
is 219 "$out" "3"
is 220 "$out" "0"
is 221 "$out" "0 0 0|1 2 3|2 4 6"
is 222 "$out" ""
is 223 "$out" "2345"
is 224 "$out" ""
is 225 "$out" "yes"
is 226 "$out" "no"
is 227 "$out" "3,2,1"
is 228 "$out" "1,2,3"
has 229 "$out" "\"text\":\"too big\""; has 229 "$out" "\"isError\":true"
is 230 "$out" "5"
is 231 "$out" ""
is 232 "$out" "5"
is 233 "$out" "yes"
is 234 "$out" "no"
is 235 "$out" "3/2"
is 240 "$out" "empty"
is 241 "$out" "long"
has 242 "$out" "\"text\":\"digits not allowed\""; has 242 "$out" "\"isError\":true"
is 243 "$out" "a-word"
is 244 "$out" "short"
is 245 "$out" "1,2,3"
is 246 "$out" "big"
echo "OK: lists, nil-able values, case/when and the character methods answer like Ruby"
