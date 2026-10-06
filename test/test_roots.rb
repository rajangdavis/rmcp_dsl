# frozen_string_literal: true

# L5 for roots, run by `make test-ruby`: a tool body asks the client for its roots with a server-to-client
# request (`roots/list`). An ordinary tools/call test only reads replies; this client also has to recognize
# the server's request, reply with a couple of roots (one with a name, one without), and keep waiting for its
# own reply. The tool's result must reflect the uris and names, and a client that does not support roots makes
# the call a normal error result. The crate is built once and shared by both tests.
require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "timeout"
require "tmpdir"

class TestRoots < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)
  EXAMPLE = File.expand_path("../examples/rootskit.rmcp.rb", __dir__)

  # Build the example once; both tests run the same binary.
  def self.build_dir
    @build_dir ||= begin
      dir = Dir.mktmpdir("roots-out")
      _out, err, status = Open3.capture3(RbConfig.ruby, EXE, "build", EXAMPLE, "-o", dir)
      raise "could not build examples/rootskit.rmcp.rb:\n#{err}" unless status.success?

      dir
    end
  end

  def setup
    @dir = self.class.build_dir
  end

  # A raw JSON-RPC client over stdio that answers roots/list requests while it waits for a reply. With
  # roots: false it declares no roots capability and answers the server's request with an error, the way an
  # unsupported client would.
  class Client
    def initialize(dir, roots: true)
      @in, @out, @err, @wait = Open3.popen3("cargo", "run", "-q", chdir: dir)
      @next = 1
      @roots = roots
      @asked = []
      @init = request("initialize", {
        "protocolVersion" => "2025-06-18",
        "capabilities" => roots ? { "roots" => { "listChanged" => false } } : {},
        "clientInfo" => { "name" => "e2e", "version" => "0" },
      })
      send_line({ "jsonrpc" => "2.0", "method" => "notifications/initialized" })
    end

    attr_reader :init, :asked

    def send_line(msg)
      @in.puts(JSON.generate(msg))
      @in.flush
    end

    def request(method, params = nil)
      id = @next
      @next += 1
      msg = { "jsonrpc" => "2.0", "id" => id, "method" => method }
      msg["params"] = params if params
      send_line(msg)
      Timeout.timeout(180) do # the first call waits for cargo
        loop do
          line = @out.gets or raise "the server closed its output (stderr: #{@err.read})"
          reply = JSON.parse(line)
          if reply["method"] == "roots/list" && reply.key?("id")
            @asked << reply
            send_line(roots_answer(reply["id"]))
            next
          end
          next unless reply["id"] == id # notifications have no id; other directions do not match

          return reply
        end
      end
    end

    def call(name, args) = request("tools/call", { "name" => name, "arguments" => args })

    def roots_answer(id)
      return { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => -32601, "message" => "Method not found" } } unless @roots

      { "jsonrpc" => "2.0", "id" => id,
        "result" => { "roots" => [{ "uri" => "file:///home/raj/project", "name" => "project" },
                                  { "uri" => "file:///srv/data" }] } }
    end

    def close
      @in.close
      @wait.value
    end
  end

  def test_roots_asks_the_client_and_reports_uris_and_names
    client = Client.new(@dir)
    begin
      assert_equal "rootskit", client.init.dig("result", "serverInfo", "name"), "initialize: #{client.init}"
      listed = client.request("tools/list").dig("result", "tools").map { |t| t["name"] }
      assert_equal ["summarize_roots"], listed, "tools/list: #{listed}"

      text = client.call("summarize_roots", { "tag" => "r" }).dig("result", "content", 0, "text")
      assert_equal "count=2 r:file:///home/raj/project=project, r:file:///srv/data=-", text,
                   "the result should reflect each root's uri and (nil-able) name"
      asked = client.asked.last
      assert_equal "roots/list", asked["method"], "the server should ask with roots/list"
      assert_equal 1, client.asked.size, "one roots/list request per call"
    ensure
      client.close
    end
  end

  def test_a_client_without_roots_gets_an_error_result
    client = Client.new(@dir, roots: false)
    begin
      reply = client.call("summarize_roots", { "tag" => "r" })
      assert_equal true, reply.dig("result", "isError"), "an unsupported client should yield an error result: #{reply}"
      assert_equal "roots/list", client.asked.last["method"], "the server still issues roots/list"
    ensure
      client.close
    end
  end
end
