# frozen_string_literal: true

# L5 for taskkit: the tasks extension (io.modelcontextprotocol/tasks) over JSON-RPC. A task needs a conversation
# (the id comes back in a response and goes into the next request), so this one drives the server from Ruby.
# usage: ruby test/e2e_taskkit.rb [CRATE_DIR]      (default /tmp/taskkit-out)
require "json"
require "open3"
require "timeout"

DIR = ARGV[0] || "/tmp/taskkit-out"

def fail!(msg) = (puts "FAIL: #{msg}"; exit 1)

def check(cond, msg) = cond || fail!(msg)

class Client
  def initialize(extensions)
    @in, @out, @err, @wait = Open3.popen3("cargo", "run", "-q", chdir: DIR)
    @next = 1
    caps = extensions ? { "extensions" => { "io.modelcontextprotocol/tasks" => {} } } : {}
    @init = request("initialize", { "protocolVersion" => "2025-11-25", "capabilities" => caps, "clientInfo" => { "name" => "e2e", "version" => "0" } })
    send_line({ "jsonrpc" => "2.0", "method" => "notifications/initialized" })
  end

  attr_reader :init

  def send_line(msg) = (@in.puts(JSON.generate(msg)); @in.flush)

  def request(method, params = nil)
    id = @next
    @next += 1
    msg = { "jsonrpc" => "2.0", "id" => id, "method" => method }
    msg["params"] = params if params
    send_line(msg)
    Timeout.timeout(120) do # the first call waits for cargo to build
      loop do
        line = @out.gets or fail!("server closed its output (stderr: #{@err.read})")
        reply = JSON.parse(line)
        return reply if reply["id"] == id
      end
    end
  end

  def call(name, args) = request("tools/call", { "name" => name, "arguments" => args })

  def close
    @in.close
    @wait.value
  end
end

def poll(client, task_id)
  Timeout.timeout(20) do
    loop do
      reply = client.request("tasks/get", { "taskId" => task_id })
      check(reply["result"], "tasks/get failed: #{reply}")
      return reply["result"] if %w[completed failed cancelled].include?(reply["result"]["status"])

      sleep 0.05
    end
  end
end

# A client that declared the extension
with = Client.new(true)
check(with.init.dig("result", "capabilities", "extensions")&.key?("io.modelcontextprotocol/tasks"), "the server should advertise the tasks extension: #{with.init}")
listed = with.request("tools/list").dig("result", "tools").map { |t| t["name"] }
check(listed.sort == %w[quick slow], "tools/list: #{listed}")

created = with.call("slow", { "ms" => 300 })["result"]
check(created["resultType"] == "task", "slow should answer with a task handle: #{created}")
check(created["taskId"].is_a?(String) && !created["taskId"].empty?, "a task has an id: #{created}")
check(created["status"] == "working", "a new task is working: #{created}")
check(created["ttlMs"] == 60_000 && created["pollIntervalMs"] == 100, "ttl and poll interval come from the DSL: #{created}")

first = with.request("tasks/get", { "taskId" => created["taskId"] })["result"]
check(first["status"] == "working", "the body is still sleeping, so the task is working: #{first}")
done = poll(with, created["taskId"])
check(done["status"] == "completed", "the task should complete: #{done}")
check(done.dig("result", "content", 0, "text") == "slept 300 ms", "the task carries the tool's result: #{done}")

# a tool without `task:` never becomes a task
direct = with.call("quick", { "ms" => 10 })["result"]
check(direct["resultType"] != "task" && direct.dig("content", 0, "text") == "slept 10 ms", "quick answers directly: #{direct}")

# an argument the tool refuses becomes the task's own (error) result, as a plain call would answer it
bad = with.call("slow", { "ms" => 6000 })["result"]
check(bad["resultType"] == "task", "the task is created before the arguments are checked: #{bad}")
refused = poll(with, bad["taskId"])
check(refused["status"] == "completed" && refused.dig("result", "isError") == true, "an out-of-range argument ends as an error result: #{refused}")

# cancelling is acknowledged (cooperative: a finished task keeps its result)
ack = with.request("tasks/cancel", { "taskId" => created["taskId"] })
check(ack["result"] && !ack["error"], "tasks/cancel is acknowledged: #{ack}")
check(poll(with, created["taskId"])["status"] == "completed", "a finished task stays completed")

# an unknown task is invalid params
unknown = with.request("tasks/get", { "taskId" => "no-such-task" })
check(unknown.dig("error", "code") == -32_602, "an unknown task id is -32602: #{unknown}")
with.close

# a client that did not declare the extension never gets a task
without = Client.new(false)
plain = without.call("slow", { "ms" => 10 })["result"]
check(plain["resultType"] != "task" && plain.dig("content", 0, "text") == "slept 10 ms", "no extension, no task: #{plain}")
refused = without.request("tasks/get", { "taskId" => created["taskId"] })
check(refused["error"], "tasks/get needs the extension: #{refused}")
without.close

puts "OK: taskkit answers a task handle to clients that declared the tasks extension, and the plain result to the rest"
