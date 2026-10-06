# frozen_string_literal: true

# L5 for elicitation, run by `make test-ruby`: a tool body asks the client for input with a
# server-to-client request (`elicitation/create`). An ordinary tools/call test only reads replies;
# this client also has to recognize the server's request, reply with a chosen action and content,
# and keep waiting for its own reply. The tool's result must reflect both fields.
require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "timeout"
require "tmpdir"

class TestElicitation < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)
  EXAMPLE = File.expand_path("../examples/elicitation.rmcp.rb", __dir__)

  # A raw JSON-RPC client over stdio that answers elicitation requests while it waits for a reply.
  class Client
    def initialize(dir)
      @in, @out, @err, @wait = Open3.popen3("cargo", "run", "-q", chdir: dir)
      @next = 1
      @mode = :accept
      @asked = []
      @init = request("initialize", {
        "protocolVersion" => "2025-06-18",
        "capabilities" => { "elicitation" => {} },
        "clientInfo" => { "name" => "e2e", "version" => "0" },
      })
      send_line({ "jsonrpc" => "2.0", "method" => "notifications/initialized" })
    end

    attr_reader :init, :asked
    attr_accessor :mode

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
          if reply["method"] == "elicitation/create" && reply.key?("id")
            @asked << reply
            send_line({ "jsonrpc" => "2.0", "id" => reply["id"], "result" => elicitation_answer })
            next
          end
          next unless reply["id"] == id # notifications have no id; other directions do not match

          return reply
        end
      end
    end

    def call(name, args) = request("tools/call", { "name" => name, "arguments" => args })

    def elicitation_answer
      return { "action" => "decline" } if @mode == :decline

      { "action" => "accept", "content" => { "name" => "Ada" } }
    end

    def close
      @in.close
      @wait.value
    end
  end

  def test_elicit_asks_the_client_and_reports_the_action_and_content
    Dir.mktmpdir("elicitation-out") do |dir|
      _out, build_err, status = Open3.capture3(RbConfig.ruby, EXE, "build", EXAMPLE, "-o", dir)
      assert status.success?, "could not build examples/elicitation.rmcp.rb:\n#{build_err}"

      client = Client.new(dir)
      begin
        assert_equal "elicitation", client.init.dig("result", "serverInfo", "name"), "initialize: #{client.init}"
        listed = client.request("tools/list").dig("result", "tools").map { |t| t["name"] }
        assert_equal ["ask"], listed, "tools/list: #{listed}"

        client.mode = :accept
        accepted = client.call("ask", { "question" => "What is your name?" }).dig("result", "content", 0, "text")
        assert_equal 'accept:{"name":"Ada"}', accepted, "the accept result should reflect action and content"
        asked = client.asked.last
        assert_equal "elicitation/create", asked["method"], "the server should ask with elicitation/create"
        assert_equal "What is your name?", asked.dig("params", "message"), "the question is the message"
        assert_equal "string", asked.dig("params", "requestedSchema", "properties", "name", "type"), "the schema is sent"

        client.mode = :decline
        declined = client.call("ask", { "question" => "Once more?" }).dig("result", "content", 0, "text")
        assert_equal "decline:", declined, "the decline result keeps the action and an empty content"
        assert_equal "Once more?", client.asked.last.dig("params", "message"), "the second question is sent"
        assert_equal 2, client.asked.size, "one elicitation request per call"
      ensure
        client.close
      end
    end
  end
end
