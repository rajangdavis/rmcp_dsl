#!/bin/sh
# L5 for logkit: a server that declares `feature :logging` (deprecated by SEP-2577) advertises the logging
# capability, answers logging/setLevel instead of method_not_found, and emits notifications/message with the
# level and data the tool body gave.
# usage: sh test/e2e_logkit.sh [CRATE_DIR]      (default /tmp/logkit-out)
set -eu
dir=${1:-/tmp/logkit-out}
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
setlevel='{"jsonrpc":"2.0","id":2,"method":"logging/setLevel","params":{"level":"warning"}}'
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$1" "$2" "$3"; }

out=$( { printf '%s\n%s\n%s\n' "$init" "$inited" "$setlevel"
         call 10 log_info '{"message":"hello"}'
         call 11 log_warning '{"message":"careful"}'
         sleep 2; } | (cd "$dir" && cargo run -q) )
printf '%s\n' "$out" | cut -c1-220

fail() { echo "FAIL: $1"; exit 1; }
has() { printf '%s\n' "$2" | grep "\"id\":$1," | grep -qF -- "$3" || fail "id $1 should contain: $3"; }

# The logging capability is advertised in initialize.
has 1 "$out" '"logging":{}'
# logging/setLevel is accepted (rmcp's default would answer method_not_found, an error).
has 2 "$out" '"result":{}'
if printf '%s\n' "$out" | grep '"id":2,' | grep -q '"error"'; then fail "logging/setLevel must not be method_not_found"; fi
# Both tools answer, and the log notifications carry the level and data.
has 10 "$out" 'logged at info'
has 11 "$out" 'logged at warning'
printf '%s\n' "$out" | grep -q '"method":"notifications/message"' || fail "logging notification"
printf '%s\n' "$out" | grep -q '"level":"info"' || fail "info level"
printf '%s\n' "$out" | grep -q '"level":"warning"' || fail "warning level"
printf '%s\n' "$out" | grep -q '"data":"hello"' || fail "info data"
printf '%s\n' "$out" | grep -q '"data":"careful"' || fail "warning data"
# The notification for a call arrives before its result.
il=$(printf '%s\n' "$out" | grep -n '"level":"info"' | head -1 | cut -d: -f1)
rl=$(printf '%s\n' "$out" | grep -n '"id":10,' | head -1 | cut -d: -f1)
[ -n "$il" ] && [ -n "$rl" ] && [ "$il" -lt "$rl" ] || fail "the info log must arrive before its result"
# tools/list_changed: hide a tool, check the new list and the refusal, show it again, check the list.
ruby - "$dir" <<'RUBY'
require "json"
require "open3"

dir = ARGV.fetch(0)

def rpc(id, method, params)
  { "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params }
end

Open3.popen2("cargo", "run", "-q", chdir: dir) do |stdin, stdout, wait|
  seen = []
  send_line = lambda do |hash|
    stdin.puts(JSON.generate(hash))
    stdin.flush
  end
  # Read lines until the response for `id` arrives, collecting every notification seen on the way.
  await = lambda do |id|
    loop do
      line = stdout.gets
      raise "the server closed its output before responding to id #{id}" unless line
      seen << line
      return line if line.include?(%Q("id":#{id},))
    end
  end

  send_line.call(rpc(1, "initialize", { "protocolVersion" => "2025-03-26", "capabilities" => {}, "clientInfo" => { "name" => "e2e", "version" => "0" } }))
  init = await.call(1)
  raise "initialize should advertise tools.listChanged: #{init}" unless init.include?(%Q("listChanged":true))
  send_line.call({ "jsonrpc" => "2.0", "method" => "notifications/initialized" })
  sleep 0.2

  send_line.call(rpc(20, "tools/list", {}))
  before = await.call(20)
  %w[log_info silence_log_info restore_log_info].each do |name|
    raise "tools/list before hiding should list #{name}: #{before}" unless before.include?(%Q("name":"#{name}"))
  end

  send_line.call(rpc(21, "tools/call", { "name" => "silence_log_info", "arguments" => { "message" => "quiet" } }))
  hidden = await.call(21)
  raise "silence_log_info should succeed: #{hidden}" unless hidden.include?("hidden log_info: quiet")

  send_line.call(rpc(22, "tools/list", {}))
  after = await.call(22)
  raise "tools/list must omit the hidden log_info: #{after}" if after.include?(%Q("name":"log_info"))

  send_line.call(rpc(23, "tools/call", { "name" => "log_info", "arguments" => { "message" => "hidden" } }))
  refused = await.call(23)
  raise "a hidden tool must be refused: #{refused}" unless refused.include?(%Q("error")) && refused.include?("tool not found")

  send_line.call(rpc(25, "tools/call", { "name" => "restore_log_info", "arguments" => { "message" => "loud" } }))
  shown = await.call(25)
  raise "restore_log_info should succeed: #{shown}" unless shown.include?("restored log_info: loud")

  send_line.call(rpc(26, "tools/list", {}))
  restored = await.call(26)
  raise "tools/list must offer log_info again: #{restored}" unless restored.include?(%Q("name":"log_info"))

  changes = seen.count { |line| line.include?(%Q("method":"notifications/tools/list_changed")) }
  raise "expected a tools/list_changed notification after hiding and showing, saw #{changes}" if changes < 2

  stdin.close
  wait.value
end
RUBY
echo "OK: logkit advertises logging and tools/list_changed, emits notifications/message, and hides/restores a tool"
