# frozen_string_literal: true

# L5 for sampling, run by `make test-ruby`: a tool body asks the client's LLM for a completion with a
# server-to-client request (`sampling/createMessage`). An ordinary tools/call test only reads replies; this
# client also has to recognize the server's request, answer it with a model, a stop reason and an assistant
# text message, and keep waiting for its own reply. The tool's result must reflect the text, the model and
# the stop reason, and a client that does not support sampling makes the call a normal error result. The
# crate is built once and shared by both tests.
require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "timeout"
require "tmpdir"

class TestSampling < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)
  EXAMPLE = File.expand_path("../examples/samplingkit.rmcp.rb", __dir__)

  # Build the example once; both tests run the same binary.
  def self.build_dir
    @build_dir ||= begin
      dir = Dir.mktmpdir("sampling-out")
      _out, err, status = Open3.capture3(RbConfig.ruby, EXE, "build", EXAMPLE, "-o", dir)
      raise "could not build examples/samplingkit.rmcp.rb:\n#{err}" unless status.success?

      dir
    end
  end

  def setup
    @dir = self.class.build_dir
  end

  # A raw JSON-RPC client over stdio that answers sampling/createMessage requests while it waits for a
  # reply. With sampling: false it declares no sampling capability and answers the server's request with an
  # error, the way an unsupported client would.
  class Client
    def initialize(dir, sampling: true)
      @in, @out, @err, @wait = Open3.popen3("cargo", "run", "-q", chdir: dir)
      @next = 1
      @sampling = sampling
      @asked = []
      @init = request("initialize", {
        "protocolVersion" => "2025-06-18",
        "capabilities" => sampling ? { "sampling" => {} } : {},
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
          if reply["method"] == "sampling/createMessage" && reply.key?("id")
            @asked << reply
            send_line(sampling_answer(reply["id"]))
            next
          end
          next unless reply["id"] == id # notifications have no id; other directions do not match

          return reply
        end
      end
    end

    def call(name, args) = request("tools/call", { "name" => name, "arguments" => args })

    def sampling_answer(id)
      return { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => -32601, "message" => "Method not found" } } unless @sampling

      { "jsonrpc" => "2.0", "id" => id,
        "result" => { "model" => "e2e-model", "stopReason" => "endTurn", "role" => "assistant",
                      "content" => { "type" => "text", "text" => "a concise answer" } } }
    end

    def close
      @in.close
      @wait.value
    end
  end

  def test_sampling_asks_the_client_and_reports_text_model_and_stop_reason
    client = Client.new(@dir)
    begin
      assert_equal "samplingkit", client.init.dig("result", "serverInfo", "name"), "initialize: #{client.init}"
      listed = client.request("tools/list").dig("result", "tools").map { |t| t["name"] }
      assert_equal ["complete"], listed, "tools/list: #{listed}"

      text = client.call("complete", { "prompt" => "say hi", "max_tokens" => 16 }).dig("result", "content", 0, "text")
      assert_equal "model=e2e-model stop=endTurn role=assistant text=a concise answer", text,
                   "the result should reflect the model, stop reason, role and text"
      asked = client.asked.last
      assert_equal "sampling/createMessage", asked["method"], "the server should ask with sampling/createMessage"
      assert_equal 1, client.asked.size, "one sampling/createMessage request per call"
    end
  ensure
    client.close
  end

  def test_a_client_without_sampling_gets_an_error_result
    client = Client.new(@dir, sampling: false)
    begin
      reply = client.call("complete", { "prompt" => "say hi", "max_tokens" => 16 })
      assert_equal true, reply.dig("result", "isError"), "an unsupported client should yield an error result: #{reply}"
      assert_equal "sampling/createMessage", client.asked.last["method"], "the server still issues sampling/createMessage"
    end
  ensure
    client.close
  end
end
