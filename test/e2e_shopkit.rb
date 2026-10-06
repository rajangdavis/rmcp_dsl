# frozen_string_literal: true

# L5 for shopkit: the tools made from an OpenAPI document, and the HTTP requests they make, seen by a local API.
# usage: ruby test/e2e_shopkit.rb [CRATE_DIR]      (default /tmp/shopkit-out)
require "json"
require "open3"
require "socket"
require "timeout"

DIR = ARGV[0] || "/tmp/shopkit-out"
KEY = "key-4321-secret"

def fail!(msg) = (puts "FAIL: #{msg}"; exit 1)

def check(cond, msg) = cond || fail!(msg)

# A local shop API. Every request is recorded as it arrived: method, the path with its query as written, headers, body.
class FakeShop
  attr_reader :requests, :port

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @requests = []
    @thread = Thread.new { loop { handle(@server.accept) } }
  end

  def close = (@thread.kill; @server.close)

  def handle(sock)
    method, target, = sock.gets.to_s.split
    headers = {}
    while (h = sock.gets) && h != "\r\n"
      k, v = h.split(": ", 2)
      headers[k.downcase] = v.to_s.strip
    end
    body = headers["content-length"] ? sock.read(headers["content-length"].to_i) : nil
    @requests << { method: method, target: target, headers: headers, body: body }
    path = target.split("?").first
    status, text =
      if method == "GET" && path == "/items" then [200, %([{"query":#{target.split('?', 2)[1].to_s.to_json}}])]
      elsif method == "GET" && path == "/items/404" then [404, %({"error":"not found"})]
      elsif method == "GET" && path.start_with?("/items/") then [200, %({"path":#{path.to_json},"request_id":#{headers['x-request-id'].to_json}})]
      elsif method == "POST" && path == "/items" && headers["x-api-key"] == KEY then [201, %({"created":#{body}})]
      elsif method == "POST" && path == "/items" then [401, "no key"]
      else [500, "unexpected"]
      end
    sock.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: #{text.bytesize}\r\nConnection: close\r\n\r\n#{text}")
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

shop = FakeShop.new
env = { "SHOPKIT_URL" => "http://127.0.0.1:#{shop.port}/", "SHOPKIT_KEY" => KEY }
client = Client.new(env)

# the tools: one per operation that was not excluded, named from the operationId, with HTTP's own hints
tools = client.request("tools/list").dig("result", "tools").to_h { |t| [t["name"], t] }
check(tools.keys.sort == %w[create_item get_item list_items], "tools: #{tools.keys}")
check(tools["list_items"]["description"] == "List items\n\nNewest first.", "description: #{tools['list_items']['description']}")
check(tools["list_items"]["annotations"] == { "readOnlyHint" => true, "openWorldHint" => true }, "annotations: #{tools['list_items']['annotations']}")
check(tools["create_item"]["annotations"] == { "openWorldHint" => true }, "a POST has no hints but open world: #{tools['create_item']['annotations']}")
# the schema is the document's, with the Item schema bundled
schema = tools["create_item"]["inputSchema"]
check(schema["required"] == ["body"] && schema["properties"]["body"] == { "$ref" => "#/$defs/Item" }, "schema: #{schema}")
check(schema["$defs"]["Item"]["properties"]["name"]["description"] == "What the item is called", "the bundled Item: #{schema['$defs']}")
check(tools["list_items"]["inputSchema"]["properties"]["limit"]["maximum"] == 100, "limit keeps its bounds")

# a query: the list repeats, the order is the document's, nothing else is added
r = client.call("list_items", { "limit" => 2, "tag" => %w[a b] })
check(!r["isError"], "list_items: #{r}")
answer = JSON.parse(client.text(r))
check(answer["status"] == 200 && answer["body"] == [{ "query" => "limit=2&tag=a&tag=b" }], "list_items answers {status, body}: #{answer}")
check(shop.requests.last[:headers]["x-api-key"] == KEY, "every request carries the key: #{shop.requests.last[:headers]}")
# a path value is percent-encoded, and a header argument is sent as the header the document names
r = client.call("get_item", { "id" => "a b/c", "x_request_id" => "req-1" })
body = JSON.parse(client.text(r))["body"]
check(body == { "path" => "/items/a%20b%2Fc", "request_id" => "req-1" }, "get_item: #{body}")
# a client error is the same text as an error result: the model can read it
r = client.call("get_item", { "id" => "404" })
check(r["isError"], "a 404 is an error result: #{r}")
check(JSON.parse(client.text(r)) == { "status" => 404, "body" => { "error" => "not found" } }, "the 404 text: #{client.text(r)}")
# a JSON body goes out as JSON with its own content type
r = client.call("create_item", { "body" => { "name" => "cup", "price" => 3 } })
check(!r["isError"] && JSON.parse(client.text(r))["status"] == 201, "create_item: #{r}")
sent = shop.requests.last
check(sent[:headers]["content-type"] == "application/json" && JSON.parse(sent[:body]) == { "name" => "cup", "price" => 3 }, "the body that was sent: #{sent}")
# the server still checks what the document says it checks: limit's bounds, and the required body
r = client.call("list_items", { "limit" => 0 })
check(r["isError"] && client.text(r).include?("limit"), "limit 0 is refused before any request: #{r}")
r = client.call("create_item", {})
check(r["isError"] && client.text(r).include?("missing field `body`"), "a missing body: #{r}")
client.close

# a request that gets no answer says so (and the key is nowhere in it)
down = Client.new(env.merge("SHOPKIT_URL" => "http://127.0.0.1:1"))
r = down.call("list_items", {})
check(r["isError"] && client_text = down.text(r), "an unreachable API is an error result: #{r}")
check(client_text.include?("got no answer") && !client_text.include?(KEY), "the message: #{client_text}")
down.close
shop.close

puts "OK: shopkit makes one tool per operation of its OpenAPI document and calls the API with the settings it was given"
