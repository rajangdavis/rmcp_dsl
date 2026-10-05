# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "json"
require "rmcp_dsl"

# The server with its real hover, inlay hint and completion modules (test_lsp_server.rb injects fakes, which
# cannot notice a collaborator that is wired to the wrong name).
class TestLspIntegration < Minitest::Test
  def run_session(*messages)
    frames = messages.map { |m| json = JSON.generate(m); "Content-Length: #{json.bytesize}\r\n\r\n#{json}" }.join
    out = StringIO.new
    RmcpDsl::Lsp::Server.new(StringIO.new(frames), out).run
    out.string.scan(/Content-Length: \d+\r\n\r\n(\{.*?\})(?=Content-Length|\z)/m).flatten.map { |s| JSON.parse(s) }
  end

  def formkit
    path = File.expand_path("../examples/formkit.rb", __dir__)
    [path, "file://#{path}", File.read(path)]
  end

  def open_formkit
    path, uri, text = formkit
    [{ jsonrpc: "2.0", method: "textDocument/didOpen",
       params: { textDocument: { uri: uri, languageId: "ruby", version: 1, text: text } } }, uri, text]
  end

  def test_the_transcript_log_records_what_was_received_and_sent
    require "tmpdir"
    Dir.mktmpdir("lsp-log") do |dir|
      log = File.join(dir, "lsp.log")
      before = ENV["RMCP_DSL_LSP_LOG"]
      ENV["RMCP_DSL_LSP_LOG"] = log
      begin
        run_session({ jsonrpc: "2.0", id: 1, method: "initialize", params: { capabilities: {} } },
                    { jsonrpc: "2.0", method: "exit" })
      ensure
        before ? ENV["RMCP_DSL_LSP_LOG"] = before : ENV.delete("RMCP_DSL_LSP_LOG")
      end
      text = File.read(log)
      assert_match(/ == start pid=\d+ ruby=#{Regexp.escape(RUBY_VERSION)}/, text)
      assert_match(/ <- .*"method":"initialize"/, text)
      assert_match(/ -> .*"hoverProvider":true/, text)
      assert_match(/ == stop: exit received/, text)
    end
  end

  def test_standard_requests_that_are_not_implemented_answer_with_nothing_found
    _, uri, = formkit
    msgs = run_session({ jsonrpc: "2.0", id: 7, method: "textDocument/definition",
                         params: { textDocument: { uri: uri }, position: { line: 9, character: 13 } } },
                       { jsonrpc: "2.0", id: 8, method: "textDocument/references",
                         params: { textDocument: { uri: uri }, position: { line: 9, character: 13 }, context: { includeDeclaration: true } } },
                       { jsonrpc: "2.0", id: 9, method: "nonsense/unknown", params: {} },
                       { jsonrpc: "2.0", method: "exit" })
    definition = msgs.find { |m| m["id"] == 7 }
    outline = msgs.find { |m| m["id"] == 8 }
    unknown = msgs.find { |m| m["id"] == 9 }
    assert definition.key?("result") && definition["result"].nil?, "definition should answer null, not an error: #{definition.inspect}"
    assert_equal [], outline["result"], "references are still not implemented"
    assert_equal(-32_601, unknown.dig("error", "code"), "a method nobody defined is still method-not-found")
  end

  def test_initialize_advertises_definition_and_outline
    reply = run_session({ jsonrpc: "2.0", id: 1, method: "initialize", params: { capabilities: {} } },
                        { jsonrpc: "2.0", method: "exit" }).find { |m| m["id"] == 1 }
    assert_equal true, reply.dig("result", "capabilities", "definitionProvider")
    assert_equal true, reply.dig("result", "capabilities", "documentSymbolProvider")
  end

  def test_definition_uses_the_real_module
    open_msg, uri, text = open_formkit
    lines = text.split("\n")
    line0 = lines.index { |l| l.include?("field :address, :Address") }
    target = lines.index { |l| l.include?("params :Address do") }
    reply = run_session(open_msg,
                        { jsonrpc: "2.0", id: 5, method: "textDocument/definition",
                          params: { textDocument: { uri: uri }, position: { line: line0, character: lines[line0].index(":Address") + 2 } } },
                        { jsonrpc: "2.0", method: "exit" }).find { |m| m["id"] == 5 }
    assert_equal uri, reply.dig("result", "uri")
    assert_equal({ "start" => { "line" => target, "character" => 10 }, "end" => { "line" => target, "character" => 17 } },
                 reply.dig("result", "range"))
  end

  def test_document_symbols_use_the_real_module
    open_msg, uri, = open_formkit
    reply = run_session(open_msg,
                        { jsonrpc: "2.0", id: 6, method: "textDocument/documentSymbol", params: { textDocument: { uri: uri } } },
                        { jsonrpc: "2.0", method: "exit" }).find { |m| m["id"] == 6 }
    server = reply["result"].first
    assert_equal "formkit", server["name"]
    assert_equal %w[Address RegisterParams register stdio], server["children"].map { |c| c["name"] }
  end

  def test_hover_on_a_declaration_uses_the_real_module
    open_msg, uri, text = open_formkit
    lines = text.split("\n")
    line0 = lines.index { |l| l.include?("tool :register") }
    reply = run_session(open_msg,
                        { jsonrpc: "2.0", id: 10, method: "textDocument/hover",
                          params: { textDocument: { uri: uri }, position: { line: line0, character: 3 } } },
                        { jsonrpc: "2.0", method: "exit" }).find { |m| m["id"] == 10 }
    assert_includes reply.dig("result", "contents", "value"), "tool register(RegisterParams)"
  end

  def test_no_log_is_written_unless_asked
    assert_nil ENV["RMCP_DSL_LSP_LOG"], "the test environment should not set the log"
  end

  def test_hover_uses_the_real_hover_module
    open_msg, uri, text = open_formkit
    line0 = text.split("\n").index { |l| l.include?('greeting} #{email}') }
    col = text.split("\n")[line0].index("email") + 2
    reply = run_session(open_msg,
                        { jsonrpc: "2.0", id: 2, method: "textDocument/hover",
                          params: { textDocument: { uri: uri }, position: { line: line0, character: col } } },
                        { jsonrpc: "2.0", method: "exit" }).find { |m| m["id"] == 2 }
    refute_nil reply["result"], "hover answered null"
    assert_includes reply["result"].dig("contents", "value"), "email: String"
  end

  def test_inlay_hints_use_the_real_module
    open_msg, uri, = open_formkit
    reply = run_session(open_msg,
                        { jsonrpc: "2.0", id: 3, method: "textDocument/inlayHint",
                          params: { textDocument: { uri: uri }, range: { start: { line: 0, character: 0 }, end: { line: 60, character: 0 } } } },
                        { jsonrpc: "2.0", method: "exit" }).find { |m| m["id"] == 3 }
    assert_includes reply["result"].map { |h| h["label"] }, ": String"
  end

  def test_completion_uses_the_real_module
    _, uri, = formkit
    text = "server \"x\", version: \"0.1.0\" do\n  \n"
    reply = run_session({ jsonrpc: "2.0", method: "textDocument/didOpen",
                          params: { textDocument: { uri: uri, languageId: "ruby", version: 1, text: text } } },
                        { jsonrpc: "2.0", id: 4, method: "textDocument/completion",
                          params: { textDocument: { uri: uri }, position: { line: 1, character: 2 } } },
                        { jsonrpc: "2.0", method: "exit" }).find { |m| m["id"] == 4 }
    assert_includes reply["result"]["items"].map { |i| i["label"] }, "params"
  end
end
