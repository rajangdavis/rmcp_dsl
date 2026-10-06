# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "json"
require "rmcp_dsl"

class TestLspServer < Minitest::Test
  PATH = File.expand_path("../examples/statkit.rmcp.rb", __dir__)
  URI_ = "file://#{PATH}"

  class FakeHover
    attr_reader :calls

    def initialize = @calls = []

    def at(analysis, line, col)
      @calls << [analysis.class, line, col]
      { "contents" => { "kind" => "markdown", "value" => "fake" } }
    end
  end

  class FakeInlay
    def for(_analysis, from, to) = [{ "position" => { "line" => from, "character" => to }, "label" => ": T" }]
  end

  class FakeCompletion
    def at(_analysis, line, col) = [{ "label" => "x#{line}_#{col}" }]
  end

  class Raiser
    def at(*) = raise("boom")
    def for(*) = raise("boom")
  end

  def frame(hash)
    body = JSON.generate(hash)
    "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
  end

  def request(id, method, params = {}) = { "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params }
  def notification(method, params = {}) = { "jsonrpc" => "2.0", "method" => method, "params" => params }

  # Runs the server over real framing and returns every message it wrote.
  def converse(*messages, **collaborators)
    input = StringIO.new(messages.map { |m| frame(m) }.join)
    output = StringIO.new
    RmcpDsl::Lsp::Server.new(input, output, **collaborators).run
    parse_frames(output.string)
  end

  def parse_frames(raw)
    raw = raw.b
    out = []
    until raw.empty?
      head, rest = raw.split("\r\n\r\n", 2)
      length = head[/Content-Length: (\d+)/, 1].to_i
      out << JSON.parse(rest.byteslice(0, length).force_encoding("UTF-8"))
      raw = rest.byteslice(length, rest.bytesize).to_s
    end
    out
  end

  def open_doc(text, version = 1)
    notification("textDocument/didOpen", "textDocument" => { "uri" => URI_, "languageId" => "ruby", "version" => version, "text" => text })
  end

  def good = File.read(PATH)
  def broken = good.sub("i.upcase", "i.upcas")
  def reply(out, id) = out.find { |m| m["id"] == id }
  def published(out) = out.select { |m| m["method"] == "textDocument/publishDiagnostics" }

  def test_initialize_advertises_capabilities
    out = converse(request(1, "initialize", "capabilities" => {}), notification("initialized"), request(2, "shutdown"), notification("exit"))
    caps = reply(out, 1)["result"]["capabilities"]
    assert_equal({ "openClose" => true, "change" => 1, "save" => { "includeText" => false } }, caps["textDocumentSync"])
    assert_equal [".", ":", "|", " "], caps["completionProvider"]["triggerCharacters"]
    assert_equal ["quickfix"], caps["codeActionProvider"]["codeActionKinds"]
    assert caps["hoverProvider"]
    assert caps["inlayHintProvider"]
    assert_equal({ "name" => "rmcp_dsl", "version" => RmcpDsl::VERSION }, reply(out, 1)["result"]["serverInfo"])
    assert_nil reply(out, 2)["result"]
    assert reply(out, 2).key?("result")
  end

  def test_did_open_publishes_the_diagnostic
    out = converse(open_doc(broken))
    pub = published(out).last["params"]
    assert_equal URI_, pub["uri"]
    d = pub["diagnostics"].last
    assert_equal "rmcp_dsl", d["source"]
    assert_equal 1, d["severity"]
    refute d.key?("code")
    assert_match(/unsupported method `upcas`/, d["message"])
    assert_includes d["data"]["suggestions"], "upcase"
    row = broken.split("\n").index { |l| l.include?("upcas ") }
    assert_equal row, d["range"]["start"]["line"]
    assert_equal row, d["range"]["end"]["line"]
    assert_operator d["range"]["end"]["character"], :>, d["range"]["start"]["character"]
  end

  def test_range_counts_utf16_units_after_non_ascii_text
    text = broken.sub("items: items.map { |i| i.upcas }", "items: items.map { |i| \"é😀\" + i.upcas }")
    d = published(converse(open_doc(text))).last["params"]["diagnostics"].last
    line = text.split("\n")[d["range"]["start"]["line"]]
    analysis = RmcpDsl::Lsp::Analysis.new(PATH, text)
    diag = analysis.diagnostics.last
    expected = line.byteslice(0, diag.col - 1).encode("UTF-16LE").bytesize / 2
    assert_equal expected, d["range"]["start"]["character"]
    refute_equal line.byteslice(0, diag.col - 1).length, expected if diag.col > line.index("é") + 1 # past the emoji: chars differ
  end

  def test_did_change_to_a_fixed_text_clears_the_diagnostics
    out = converse(open_doc(broken),
                   notification("textDocument/didChange", "textDocument" => { "uri" => URI_, "version" => 2 },
                                                          "contentChanges" => [{ "text" => good }]))
    pubs = published(out)
    refute_empty pubs.first["params"]["diagnostics"]
    assert_equal [], pubs.last["params"]["diagnostics"]
    assert_equal 2, pubs.last["params"]["version"]
  end

  def test_did_close_publishes_an_empty_list
    out = converse(open_doc(broken), notification("textDocument/didClose", "textDocument" => { "uri" => URI_ }))
    assert_equal [], published(out).last["params"]["diagnostics"]
  end

  def test_code_action_replaces_exactly_the_misspelt_word
    first = converse(open_doc(broken))
    diag = published(first).last["params"]["diagnostics"].last
    out = converse(open_doc(broken),
                   request(5, "textDocument/codeAction", "textDocument" => { "uri" => URI_ }, "range" => diag["range"],
                                                          "context" => { "diagnostics" => [diag] }))
    actions = reply(out, 5)["result"]
    fix = actions.find { |a| a["title"] == "Replace `upcas` with `upcase`" }
    refute_nil fix
    assert_equal "quickfix", fix["kind"]
    edit = fix["edit"]["changes"][URI_].first
    assert_equal "upcase", edit["newText"]
    line = broken.split("\n")[edit["range"]["start"]["line"]]
    assert_equal "upcas", line[edit["range"]["start"]["character"]...edit["range"]["end"]["character"]]
  end

  def test_requests_dispatch_to_the_collaborators
    hover = FakeHover.new
    out = converse(open_doc(good),
                   request(1, "textDocument/hover", "textDocument" => { "uri" => URI_ }, "position" => { "line" => 3, "character" => 4 }),
                   request(2, "textDocument/inlayHint", "textDocument" => { "uri" => URI_ },
                                                        "range" => { "start" => { "line" => 1, "character" => 0 }, "end" => { "line" => 9, "character" => 0 } }),
                   request(3, "textDocument/completion", "textDocument" => { "uri" => URI_ }, "position" => { "line" => 7, "character" => 2 }),
                   hover: hover, inlay_hints: FakeInlay.new, completion: FakeCompletion.new)
    assert_equal "fake", reply(out, 1)["result"]["contents"]["value"]
    assert_equal [[RmcpDsl::Lsp::Analysis, 3, 4]], hover.calls
    assert_equal [{ "position" => { "line" => 1, "character" => 9 }, "label" => ": T" }], reply(out, 2)["result"]
    assert_equal({ "isIncomplete" => false, "items" => [{ "label" => "x7_2" }] }, reply(out, 3)["result"])
  end

  def test_a_raising_collaborator_does_not_kill_the_server
    pos = { "textDocument" => { "uri" => URI_ }, "position" => { "line" => 0, "character" => 0 } }
    out = converse(open_doc(good),
                   request(1, "textDocument/hover", pos),
                   request(2, "textDocument/inlayHint", "textDocument" => { "uri" => URI_ },
                                                        "range" => { "start" => { "line" => 0, "character" => 0 }, "end" => { "line" => 1, "character" => 0 } }),
                   request(3, "textDocument/completion", pos),
                   request(4, "shutdown"),
                   hover: Raiser.new, inlay_hints: Raiser.new, completion: Raiser.new)
    assert_nil reply(out, 1)["result"]
    assert_equal [], reply(out, 2)["result"]
    assert_equal({ "isIncomplete" => false, "items" => [] }, reply(out, 3)["result"])
    assert reply(out, 4).key?("result")
  end

  def test_a_document_that_is_not_open_is_read_from_disk
    out = converse(request(1, "textDocument/completion", "textDocument" => { "uri" => URI_ }, "position" => { "line" => 2, "character" => 1 }),
                   completion: FakeCompletion.new, hover: FakeHover.new, inlay_hints: FakeInlay.new)
    assert_equal [{ "label" => "x2_1" }], reply(out, 1)["result"]["items"]
  end

  def test_unknown_request_is_an_error_and_unknown_notification_is_ignored
    out = converse(notification("$/whatever"), request(9, "textDocument/nope"))
    assert_equal 1, out.size
    assert_equal(-32_601, reply(out, 9)["error"]["code"])
  end

  def test_uris_are_percent_decoded
    server = RmcpDsl::Lsp::Server.new(StringIO.new, StringIO.new)
    assert_equal "/a b/é.rb", server.uri_to_path("file:///a%20b/%C3%A9.rb")
  end

  def test_framing_handles_several_messages_in_one_buffer
    out = converse(request(1, "initialize"), request(2, "initialize"), request(3, "shutdown"))
    assert_equal [1, 2, 3], out.map { |m| m["id"] }
  end
end
