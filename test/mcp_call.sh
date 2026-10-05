#!/bin/sh
# Call one tool of a BUILT MCP server over stdio and print the reply text.
# usage: sh test/mcp_call.sh BINARY TOOL 'JSON_ARGUMENTS' [SECONDS_TO_WAIT]
#   sh test/mcp_call.sh /tmp/fetchkit-out/target/release/fetchkit fetch '{"url":"https://example.com"}'
# Prints the text with real newlines when jq is installed, otherwise the raw JSON reply.
set -eu
bin=$1
tool=$2
args=$3
wait=${4:-12}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"mcp_call","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
call=$(printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$tool" "$args")
out=$( (printf '%s\n%s\n%s\n' "$init" "$inited" "$call"; sleep "$wait") | "$bin" )
reply=$(printf '%s\n' "$out" | grep '"id":2,' || true)
[ -n "$reply" ] || { echo "no reply to the tool call; server output was:"; printf '%s\n' "$out"; exit 1; }
if command -v jq >/dev/null 2>&1; then
  printf '%s\n' "$reply" | jq -r '.result.content[0].text // .error'
else
  printf '%s\n' "$reply"
fi
