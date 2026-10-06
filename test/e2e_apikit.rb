# frozen_string_literal: true

# L5 for apikit: settings from the environment, a secret token passed to an HTTP client binding, and the real requests
# the server makes, seen by a small local server.
# usage: ruby test/e2e_apikit.rb [CRATE_DIR]      (default /tmp/apikit-out)
require "json"
require "open3"
require "socket"
require "timeout"

DIR = ARGV[0] || "/tmp/apikit-out"
TOKEN = "tok-1234-secret"

def fail!(msg) = (puts "FAIL: #{msg}"; exit 1)

def check(cond, msg) = cond || fail!(msg)

# A local API: GET /health, GET /items/N (needs the bearer token), POST /items (needs it too). Every request is recorded.
class FakeApi
  attr_reader :requests, :port

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @requests = []
    @thread = Thread.new { loop { handle(@server.accept) } }
  end

  def close = (@thread.kill; @server.close)

  def handle(sock)
    line = sock.gets.to_s
    method, path, = line.split
    headers = {}
    while (h = sock.gets) && h != "\r\n"
      k, v = h.split(": ", 2)
      headers[k.downcase] = v.to_s.strip
    end
    body = headers["content-length"] ? sock.read(headers["content-length"].to_i) : nil
    @requests << { method: method, path: path, headers: headers, body: body }
    authorized = headers["authorization"] == "Bearer #{TOKEN}"
    status, text =
      if path == "/health" then [200, "up"]
      elsif !authorized then [401, "no"]
      elsif method == "GET" && path.start_with?("/items/") then [200, %({"item":#{path.split('/').last}})]
      elsif method == "POST" && path == "/items" then [201, %({"created":true})]
      else [404, "none"]
      end
    sock.write("HTTP/1.1 #{status} X\r\nContent-Type: text/plain\r\nContent-Length: #{text.bytesize}\r\nConnection: close\r\n\r\n#{text}")
  ensure
    sock.close
  end
end

class Client
  def initialize(env)
    @in, @out, @err, @wait = Open3.popen3(env, "cargo", "run", "-q", chdir: DIR)
    @next = 1
    request("initialize", { "protocolVersion" => "2025-03-26", "capabilities" => {}, "clientInfo" => { "name" => "e2e", "version" => "0" } })
    send_line({ "jsonrpc" => "2.0", "method" => "notifications/initialized" })
  end

  def send_line(msg) = (@in.puts(JSON.generate(msg)); @in.flush)

  def request(method, params = nil)
    id = @next
    @next += 1
    msg = { "jsonrpc" => "2.0", "id" => id, "method" => method }
    msg["params"] = params if params
    send_line(msg)
    Timeout.timeout(60) do
      loop do
        line = @out.gets or fail!("the server closed its output (stderr: #{@err.read})")
        reply = JSON.parse(line)
        return reply if reply["id"] == id
      end
    end
  end

  def call(name, args) = request("tools/call", { "name" => name, "arguments" => args }).fetch("result")

  def text(result) = result.dig("content", 0, "text")

  def close = (@in.close; @wait.value)
end

api = FakeApi.new
env = { "APIKIT_BASE_URL" => "http://127.0.0.1:#{api.port}", "APIKIT_TOKEN" => TOKEN }
client = Client.new(env)

# no key needed for health; the request carries no Authorization header
r = client.call("health", {})
check(client.text(r) == "up" && !r["isError"], "health answers with the API's body: #{r}")
check(api.requests.last[:headers]["authorization"].nil?, "health sends no key: #{api.requests.last}")

# the secret goes out as a bearer token, and the body returned is the API's, not the key
r = client.call("item", { "id" => "7" })
check(client.text(r) == %({"item":7}), "item returns the API's body: #{r}")
check(api.requests.last[:headers]["authorization"] == "Bearer #{TOKEN}", "item sends the secret as a bearer token: #{api.requests.last}")
check(!JSON.generate(r).include?(TOKEN), "the key must not appear in the answer")

# the name is JSON-encoded by the Json binding before it is sent
r = client.call("create", { "name" => %(a "quoted" name) })
check(client.text(r) == %({"created":true}), "create returns the API's body: #{r}")
sent = api.requests.last
check(sent[:method] == "POST" && sent[:headers]["content-type"] == "application/json", "create posts JSON: #{sent}")
check(JSON.parse(sent[:body]) == { "name" => %(a "quoted" name) }, "the name is encoded: #{sent[:body]}")

# a failure from the API is the DSL's `|| raise`, not a crash, and nothing leaks the key
api.requests.clear
client.close
wrong = Client.new(env.merge("APIKIT_TOKEN" => "wrong-token"))
r = wrong.call("item", { "id" => "7" })
check(r["isError"] && client_text = wrong.text(r), "a refused request is an error result: #{r}")
check(client_text == "the API did not answer with success for item 7", "the message: #{client_text}")
check(!JSON.generate(r).include?("wrong-token"), "the key must not appear in the error")
wrong.close
api.close

# nothing listening: an error result as well, within the ten second limit
down = Client.new(env.merge("APIKIT_BASE_URL" => "http://127.0.0.1:1"))
r = down.call("item", { "id" => "7" })
check(r["isError"], "an unreachable API is an error result: #{r}")
down.close

puts "OK: apikit takes its address and token from the environment, sends the token as a bearer header and never returns it"
