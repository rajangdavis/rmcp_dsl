#!/bin/sh
# L5 for configkit: settings read from the environment at startup, a missing one stopping the server, and a secret that
# never shows up in an answer.
# usage: sh test/e2e_configkit.sh [CRATE_DIR]      (default /tmp/configkit-out)
set -eu
dir=${1:-/tmp/configkit-out}
fail() { echo "FAIL: $1"; exit 1; }
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
describe='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"describe","arguments":{}}}'
run() { { printf '%s\n%s\n%s\n' "$init" "$inited" "$describe"; sleep 3; } | (cd "$dir" && env "$@" cargo run -q); }

# a required setting that is missing stops the server before it answers anything, and the message names the variable
set +e
msg=$( (cd "$dir" && env -u CONFIGKIT_API_KEY cargo run -q 2>&1 >/dev/null </dev/null) ); code=$?
set -e
[ "$code" = 2 ] || fail "a missing required setting should exit with 2, got $code: $msg"
printf '%s\n' "$msg" | grep -qF 'CONFIGKIT_API_KEY  (api_key: the key the upstream API wants)' || fail "the message names the variable and what it is for: $msg"
printf '%s\n' "$msg" | grep -qF 'CONFIGKIT_REGION' && fail "a setting with a default is never missing: $msg"
printf '%s\n' "$msg" | grep -qF 'CONFIGKIT_LABEL' && fail "an optional setting is never missing: $msg"
# an empty value counts as not set
set +e
(cd "$dir" && env CONFIGKIT_API_KEY= cargo run -q >/dev/null 2>&1 </dev/null); code=$?
set -e
[ "$code" = 2 ] || fail "an empty required setting should exit with 2, got $code"

# defaults and optional values; the secret is used (its length is reported) but never appears in the answer
out=$(run CONFIGKIT_API_KEY=supersecret1)
printf '%s\n' "$out" | cut -c1-240
printf '%s\n' "$out" | grep '"id":2,' | grep -qF 'region eu-west, label none, key of 12 characters' || fail "defaults and the secret's length: $out"
printf '%s\n' "$out" | grep -qF 'supersecret1' && fail "the secret must not appear in any answer"
# the environment wins over the default
out=$(run CONFIGKIT_API_KEY=k CONFIGKIT_REGION=us-east CONFIGKIT_LABEL=hello)
printf '%s\n' "$out" | grep '"id":2,' | grep -qF 'region us-east, label hello, key of 1 characters' || fail "values from the environment: $out"
echo "OK: configkit reads its settings at startup, refuses to start without a required one, and keeps the secret out of answers"
