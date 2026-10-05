#!/bin/sh
# L5 for livekit: resource subscriptions and update / list_changed notifications, on both protocol generations.
# usage: sh test/e2e_livekit.sh [CRATE_DIR]      (default /tmp/livekit-out)
set -eu
dir=${1:-/tmp/livekit-out}
fail() { echo "FAIL: $1"; exit 1; }
has() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" || fail "id $1 should contain: $3"; }
count() { printf '%s\n' "$1" | grep -c -F -- "$2" || true; }
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$1" "$2" "$3"; }

# --- before 2026-07-28: initialize, then resources/subscribe
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
# The server handles requests concurrently, so a step that depends on an earlier one waits for it (sleep).
out=$( { printf '%s\n%s\n' "$init" "$inited"
         sleep 2 # initialization is done before anything else is asked
         printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"resources/subscribe","params":{"uri":"livekit://notes/7"}}'
         printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"resources/subscribe","params":{"uri":"livekit://nope"}}'
         sleep 1
         call 4 edit '{"id":"7"}'
         sleep 1
         call 5 edit '{"id":"8"}'
         sleep 1
         call 6 add '{"id":"9"}'
         sleep 1
         printf '%s\n' '{"jsonrpc":"2.0","id":7,"method":"resources/unsubscribe","params":{"uri":"livekit://notes/7"}}'
         sleep 1
         call 8 edit '{"id":"7"}'
         call 9 edit '{"id":"x"}'
         sleep 2; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-260
has 1 "$out" '"resources":{"subscribe":true,"listChanged":true}'
has 2 "$out" '"result":{}'
has 3 "$out" '"code":-32002'; has 3 "$out" 'unknown resource livekit://nope'
has 4 "$out" 'edited 7'; has 6 "$out" 'added 9'
# note 7 was subscribed when it changed, note 8 was not, and after unsubscribing nothing more arrives; a refused call changes nothing
[ "$(count "$out" '"method":"notifications/resources/updated"')" = 1 ] || fail "exactly one resources/updated expected"
printf '%s\n' "$out" | grep -qF '"method":"notifications/resources/updated","params":{"uri":"livekit://notes/7"}' || fail "the update names the note"
# the list changed once, for the call to add (every initialized client hears it)
[ "$(count "$out" '"method":"notifications/resources/list_changed"')" = 1 ] || fail "exactly one resources/list_changed expected"
has 9 "$out" '"isError":true'

# --- 2026-07-28: no initialize; every request says who it is, and subscriptions/listen is the subscription
meta='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"e2e","version":"0"},"io.modelcontextprotocol/clientCapabilities":{}}'
call26() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{%s,"name":"%s","arguments":%s}}\n' "$1" "$meta" "$2" "$3"; }
out=$( { printf '{"jsonrpc":"2.0","id":1,"method":"subscriptions/listen","params":{%s,"notifications":{"resourcesListChanged":true,"resourceSubscriptions":["livekit://notes/7","livekit://nope"]}}}\n' "$meta"
         sleep 3 # the stream is open (and acknowledged) before anything changes
         call26 2 edit '{"id":"7"}'
         sleep 1
         call26 3 edit '{"id":"8"}'
         sleep 1
         call26 4 add '{"id":"9"}'
         sleep 2; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-300
# the acknowledgement comes first and names what the server agreed to: the unknown uri is dropped
printf '%s\n' "$out" | grep -F 'notifications/subscriptions/acknowledged' | grep -qF '"resourceSubscriptions":["livekit://notes/7"]' || fail "the acknowledgement keeps only the known uri"
printf '%s\n' "$out" | grep -F 'notifications/subscriptions/acknowledged' | grep -qF '"resourcesListChanged":true' || fail "the acknowledgement keeps list changes"
printf '%s\n' "$out" | grep -F 'notifications/subscriptions/acknowledged' | grep -qF '"io.modelcontextprotocol/subscriptionId":1' || fail "the acknowledgement carries the subscription id"
# only the subscribed note and the list change arrive, each tagged with the subscription id
[ "$(count "$out" '"method":"notifications/resources/updated"')" = 1 ] || fail "exactly one resources/updated expected on the stream"
printf '%s\n' "$out" | grep -F 'notifications/resources/updated' | grep -qF '"uri":"livekit://notes/7"' || fail "the stream is told about note 7"
printf '%s\n' "$out" | grep -F 'notifications/resources/updated' | grep -qF '"io.modelcontextprotocol/subscriptionId":1' || fail "updates carry the subscription id"
[ "$(count "$out" '"method":"notifications/resources/list_changed"')" = 1 ] || fail "exactly one resources/list_changed expected on the stream"
echo "OK: livekit tells subscribed clients about changed resources and list changes, before and after 2026-07-28"
