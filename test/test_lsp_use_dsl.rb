# frozen_string_literal: true

# The editor side of use_dsl (docs/specs/use_dsl.md, Editor support): a fragment is checked through the server
# file that includes it, an error is published to the file that holds it, and definition and completion reach
# across the files.
#
#   ruby -Ilib test/test_lsp_use_dsl.rb
require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require "rmcp_dsl"

class TestLspUseDsl < Minitest::Test
  A = RmcpDsl::Lsp::Analysis

  ROOT = <<~'RB'
    server "s", version: "0.1.0" do
      use_dsl "dsl/helpers.rmcp.rb"
      use_dsl "dsl/tools.rmcp.rb"
      transport :stdio
    end
  RB

  HELPERS = <<~'RB'
    fragment do
      helper :shout, args: [:string], returns: :string do |text|
        "#{text.upcase}!"
      end
    end
  RB

  TOOLS = <<~'RB'
    fragment do
      params :P do
        field :name, :string
      end
      tool :t, params: :P, description: "d" do
        body { |name| shout(name) }
      end
    end
  RB

  def with_tree(root: ROOT, helpers: HELPERS, tools: TOOLS)
    Dir.mktmpdir("lsp-use-dsl") do |raw|
      dir = File.realpath(raw)
      FileUtils.mkdir_p(File.join(dir, "dsl"))
      File.write(File.join(dir, "s.rmcp.rb"), root)
      File.write(File.join(dir, "dsl", "helpers.rmcp.rb"), helpers)
      File.write(File.join(dir, "dsl", "tools.rmcp.rb"), tools)
      yield dir
    end
  end

  def test_a_fragment_is_checked_through_its_root
    with_tree do |dir|
      tools = File.join(dir, "dsl", "tools.rmcp.rb")
      a = A.new(tools, TOOLS)
      assert a.ok?, a.diagnostics.map(&:message).inspect
      assert_equal File.join(dir, "s.rmcp.rb"), a.root
      assert(a.types.any? { |t| t[:kind] == "parameter" && t[:name] == "name" && t[:line] == 6 }, "the fragment's own types")
      refute(a.types.any? { |t| t[:name] == "text" }, "the helper's parameter belongs to helpers.rmcp.rb")
    end
  end

  def test_an_unsaved_fragment_buffer_is_what_gets_checked
    with_tree do |dir|
      tools = File.join(dir, "dsl", "tools.rmcp.rb")
      a = A.new(tools, TOOLS.sub("shout(name)", "nope(name)"))
      refute a.ok?
      assert_equal [6], a.diagnostics.map(&:line)
      assert_empty a.elsewhere
    end
  end

  def test_a_root_points_at_the_use_dsl_line_and_reports_the_fragment_error_elsewhere
    with_tree(tools: TOOLS.sub("shout(name)", "nope(name)")) do |dir|
      a = A.new(File.join(dir, "s.rmcp.rb"), ROOT)
      assert_equal [3], a.diagnostics.map(&:line), "the use_dsl line of tools.rmcp.rb"
      assert_match(%r{dsl/tools\.rmcp\.rb:6: }, a.diagnostics[0].message)
      assert_equal [6], a.elsewhere.fetch(File.join(dir, "dsl", "tools.rmcp.rb")).map(&:line)
    end
  end

  def test_a_fragment_says_when_another_file_stops_its_check
    with_tree(root: ROOT.sub('version: "0.1.0"', 'version: "bad"')) do |dir|
      a = A.new(File.join(dir, "dsl", "tools.rmcp.rb"), TOOLS)
      assert_equal [3], a.diagnostics.map(&:severity)
      assert_match(/not checked: .*s\.rmcp\.rb stops at .*s\.rmcp\.rb:1: version must be semver/, a.diagnostics[0].message)
    end
  end

  def test_a_fragment_nothing_includes_says_so
    with_tree(root: ROOT.sub("  use_dsl \"dsl/tools.rmcp.rb\"\n", "")) do |dir|
      a = A.new(File.join(dir, "dsl", "tools.rmcp.rb"), TOOLS)
      assert_nil a.root
      assert_match(/no file says use_dsl for this fragment/, a.diagnostics[0].message)
    end
  end

  def test_definition_reaches_a_helper_in_another_fragment_and_a_use_dsl_path
    with_tree do |dir|
      tools = File.join(dir, "dsl", "tools.rmcp.rb")
      a = A.new(tools, TOOLS)
      col = TOOLS.lines[5].index("shout") + 1
      loc = RmcpDsl::Lsp::Definition.at(a, 5, col, "file://#{tools}")
      assert_equal "file://#{File.join(dir, 'dsl', 'helpers.rmcp.rb')}", loc["uri"]
      assert_equal 1, loc["range"]["start"]["line"]

      root = File.join(dir, "s.rmcp.rb")
      r = A.new(root, ROOT)
      loc = RmcpDsl::Lsp::Definition.at(r, 2, ROOT.lines[2].index("tools") + 1, "file://#{root}")
      assert_equal "file://#{tools}", loc["uri"]
    end
  end

  def test_completion_inside_a_fragment_offers_the_server_calls
    with_tree do |dir|
      a = A.new(File.join(dir, "dsl", "tools.rmcp.rb"), "fragment do\n  to")
      assert_equal %w[tool], RmcpDsl::Lsp::Completion.at(a, 1, 4).map { |i| i["label"] }
    end
  end

  def test_a_use_dsl_string_completes_the_dsl_files_below_it
    with_tree do |dir|
      root = File.join(dir, "s.rmcp.rb")
      typing = ROOT.sub("  transport", "  use_dsl \"dsl/\n  transport")
      a = A.new(root, typing)
      line0 = typing.lines.index { |l| l.include?('use_dsl "dsl/') && !l.include?(".rmcp.rb") }
      labels = RmcpDsl::Lsp::Completion.at(a, line0, typing.lines[line0].chomp.length).map { |i| i["label"] }
      assert_equal %w[dsl/helpers.rmcp.rb dsl/tools.rmcp.rb], labels.sort
    end
  end

  def test_the_server_publishes_a_fragment_error_to_the_fragment_and_clears_it
    with_tree(tools: TOOLS.sub("shout(name)", "nope(name)")) do |dir|
      root = File.join(dir, "s.rmcp.rb")
      tools_uri = "file://#{File.join(dir, 'dsl', 'tools.rmcp.rb')}"
      out = StringIO.new
      server = RmcpDsl::Lsp::Server.new(StringIO.new(""), out)
      server.send(:notify, "textDocument/didOpen",
                  { "textDocument" => { "uri" => "file://#{root}", "languageId" => "ruby", "version" => 1, "text" => ROOT } })
      File.write(File.join(dir, "dsl", "tools.rmcp.rb"), TOOLS)
      server.send(:notify, "workspace/didChangeWatchedFiles", { "changes" => [{ "uri" => tools_uri, "type" => 2 }] })

      msgs = out.string.scan(/Content-Length: \d+\r\n\r\n(\{.*?\})(?=Content-Length|\z)/m).flatten.map { |s| JSON.parse(s) }
      to_tools = msgs.select { |m| m["method"] == "textDocument/publishDiagnostics" && m.dig("params", "uri") == tools_uri }
      assert_equal [[5], []], to_tools.map { |m| m.dig("params", "diagnostics").map { |d| d.dig("range", "start", "line") } },
                   "the error on line 6 of the fragment, then cleared once it is fixed"
    end
  end
end
