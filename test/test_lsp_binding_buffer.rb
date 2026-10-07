# frozen_string_literal: true

# The compiler reads a binding (and a rust_file) from the editor's open buffer when there is one, so a
# proposed or unsaved binding is checked against the DSL instead of the older bytes on disk.
#
#   ruby -Ilib test/test_lsp_binding_buffer.rb
require "minitest/autorun"
require "stringio"
require "json"
require "tmpdir"
require "fileutils"
require "rmcp_dsl"

class TestLspBindingBuffer < Minitest::Test
  def run_session(*messages)
    frames = messages.map { |m| j = JSON.generate(m); "Content-Length: #{j.bytesize}\r\n\r\n#{j}" }.join
    out = StringIO.new
    RmcpDsl::Lsp::Server.new(StringIO.new(frames), out).run
    out.string.scan(/Content-Length: \d+\r\n\r\n(\{.*?\})(?=Content-Length|\z)/m).flatten.map { |s| JSON.parse(s) }
  end

  def uri_for(path) = "file://#{path}"

  DSL = <<~RB
    server "s", version: "0.1.0" do
      use_bindings :orphan
      params :P do
        field :s, :string
      end
      tool :t, params: :P, description: "d" do
        body do |s|
          Orphan.go(s)
        end
      end
      transport :stdio
    end
  RB

  def binding(arg_type, literal)
    <<~RB
      # typed: true
      module Orphan
        extend T::Sig
        extend RmcpDsl::BindingDsl

        rust "x"
        sig { params(x: #{arg_type}).returns(String) }
        def self.go(x) = x
        example :go, #{literal}, expect: "v"
      end
    RB
  end

  def open_doc(path, text)
    { jsonrpc: "2.0", method: "textDocument/didOpen",
      params: { textDocument: { uri: uri_for(path), languageId: "ruby", version: 1, text: text } } }
  end

  def close_doc(path)
    { jsonrpc: "2.0", method: "textDocument/didClose", params: { textDocument: { uri: uri_for(path) } } }
  end

  def diagnostics(msgs, uri)
    msgs.select { |m| m["method"] == "textDocument/publishDiagnostics" && m.dig("params", "uri") == uri && m.dig("params", "version") }
        .last&.dig("params", "diagnostics") || []
  end

  def test_a_binding_is_read_from_its_open_buffer
    Dir.mktmpdir do |raw|
      dir = File.realpath(raw)
      FileUtils.mkdir_p(File.join(dir, "bindings"))
      dsl = File.join(dir, "s.rmcp.rb")
      bpath = File.join(dir, "bindings", "orphan.rb")
      File.write(dsl, DSL)
      File.write(bpath, binding("I64", "1")) # on disk go takes an I64, so Orphan.go(s) is wrong

      exit_msg = { jsonrpc: "2.0", method: "exit" }
      on_disk = diagnostics(run_session(open_doc(dsl, DSL), close_doc(dsl), exit_msg), uri_for(dsl))
      refute_empty on_disk, "the on-disk binding is wrong, so the DSL should have a diagnostic"

      from_buffer = diagnostics(run_session(open_doc(bpath, binding("String", '"v"')), open_doc(dsl, DSL),
                                            close_doc(dsl), close_doc(bpath), exit_msg), uri_for(dsl))
      assert_empty from_buffer, "the open binding buffer should be used instead of disk:\n#{from_buffer.inspect}"
    end
  end

  def test_a_binding_change_refreshes_the_dsl
    Dir.mktmpdir do |raw|
      dir = File.realpath(raw)
      FileUtils.mkdir_p(File.join(dir, "bindings"))
      dsl = File.join(dir, "s.rmcp.rb")
      bpath = File.join(dir, "bindings", "orphan.rb")
      File.write(dsl, DSL)
      File.write(bpath, binding("I64", "1"))

      msgs = run_session(
        open_doc(dsl, DSL),
        open_doc(bpath, binding("I64", "1")),
        { jsonrpc: "2.0", method: "textDocument/didChange",
          params: { textDocument: { uri: uri_for(bpath), version: 2 }, contentChanges: [{ text: binding("String", '"v"') }] } },
        close_doc(dsl), close_doc(bpath),
        { jsonrpc: "2.0", method: "exit" }
      )
      latest = msgs.select { |m| m["method"] == "textDocument/publishDiagnostics" && m.dig("params", "uri") == uri_for(dsl) }.last
      refute_nil latest, "the DSL should have been published at least once"
      assert_empty latest.dig("params", "diagnostics"), "the DSL should be re-analysed after its binding changed"
    end
  end
end
