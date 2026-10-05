# frozen_string_literal: true

require "minitest/autorun"
require "rmcp_dsl"

class TestLspHover < Minitest::Test
  EXAMPLES = File.expand_path("../examples", __dir__)

  def analyse(name)
    path = File.join(EXAMPLES, name)
    RmcpDsl::Lsp::Analysis.new(path, File.read(path))
  end

  # LSP position of the nth (0-based) occurrence of `needle`, `offset` characters in, as [line0, utf16_col].
  def spot(analysis, needle, offset = 0, nth: 0)
    seen = 0
    analysis.lines.each_with_index do |text, i|
      from = 0
      while (idx = text.index(needle, from))
        return [i, text[0, idx + offset].encode("UTF-16LE").bytesize / 2] if seen == nth

        seen += 1
        from = idx + 1
      end
    end
    flunk "no #{needle.inspect}"
  end

  def hover_text(analysis, needle, offset = 0, nth: 0)
    h = RmcpDsl::Lsp::Hover.at(analysis, *spot(analysis, needle, offset, nth: nth))
    h && h.dig("contents", "value")
  end

  def test_parameter_read
    a = analyse("formkit.rb")
    value = hover_text(a, "#{"{"}greeting}", 2)
    assert_includes value, "greeting: String"
    assert_includes value, "block parameter"
    assert_includes value, "```ruby"
  end

  def test_hover_range_covers_the_identifier
    a = analyse("formkit.rb")
    h = RmcpDsl::Lsp::Hover.at(a, *spot(a, "#{"{"}greeting}", 2))
    line, col = spot(a, "#{"{"}greeting}", 2)
    assert_equal line, h["range"]["start"]["line"]
    assert_operator h["range"]["start"]["character"], :<=, col
    assert_operator h["range"]["end"]["character"], :>, col
    assert_equal "markdown", h["contents"]["kind"]
  end

  def test_helper_call
    a = analyse("webkit.rb")
    value = hover_text(a, "checked_host(url)", 3, nth: 0)
    assert_includes value, "String"
  end

  def test_nilable_first
    a = analyse("webkit.rb")
    value = hover_text(a, "checked_addresses(url).first", "checked_addresses(url).".size + 1)
    assert_includes value, "nilable"
  end

  def test_nested_field_read
    a = analyse("formkit.rb")
    assert_includes hover_text(a, "address.city", 9), "String"
    assert_includes hover_text(a, "address.city", 2), "address"
  end

  def test_result
    a = analyse("statkit.rb")
    line = a.lines.index { |l| l.include?("result(") }
    flunk "no result( in statkit" unless line
    value = hover_text(a, "result(:Stats", 1)
    assert_includes value, "Output"
  end

  def test_whitespace_is_nil
    a = analyse("formkit.rb")
    assert_nil RmcpDsl::Lsp::Hover.at(a, 0, 0 + a.line_text(1).size + 5)
    assert_nil RmcpDsl::Lsp::Hover.at(a, 3, 0)
  end

  def test_utf16_columns_after_non_ascii
    text = <<~RB
      server "x", version: "0.1.0" do
        params :P do
          field :name, :string
        end
        tool :t, params: :P, description: "é😀" do
          body do |name|
            "é😀 \#{name}"
          end
        end
        transport :stdio
      end
    RB
    a = RmcpDsl::Lsp::Analysis.new(File.join(EXAMPLES, "utf.rb"), text)
    line0 = a.lines.index { |l| l.include?('é😀 #' + '{') }
    value = RmcpDsl::Lsp::Hover.at(a, line0, a.lines[line0].index("name}").then { |i| a.lines[line0][0, i + 1].encode("UTF-16LE").bytesize / 2 })
    assert value, a.diagnostics.inspect
    assert_includes value["contents"]["value"], "name: String"
    start = value["range"]["start"]["character"]
    assert_equal a.lines[line0][0, a.lines[line0].index("name}")].encode("UTF-16LE").bytesize / 2, start
  end

  def test_inlay_hints_for_block_parameters
    a = analyse("formkit.rb")
    line0 = a.lines.index { |l| l.include?("do |email, tags") }
    hints = RmcpDsl::Lsp::InlayHints.for(a, line0, line0)
    assert_equal 6, hints.size, hints.inspect
    assert_equal [": String", ": T::Array[String]"].first, hints.first["label"]
    text = a.lines[line0]
    assert_equal text.index("email") + 5, hints.first["position"]["character"]
    assert_equal false, hints.first["paddingLeft"]
    assert_equal 1, hints.first["kind"]
    assert(hints.all? { |h| h["position"]["line"] == line0 })
  end

  def test_inlay_hint_for_a_local_assignment_and_none_for_reads
    a = analyse("webkit.rb")
    line0 = a.lines.index { |l| l.include?("host = checked_host(url)") }
    hints = RmcpDsl::Lsp::InlayHints.for(a, line0, line0)
    assert_equal 1, hints.size, hints.inspect
    assert_equal ": String", hints.first["label"]
    assert_equal a.lines[line0].index("host") + 4, hints.first["position"]["character"]
    read_line = a.lines.index { |l| l.include?("page.start_with?") }
    assert_equal [], RmcpDsl::Lsp::InlayHints.for(a, read_line, read_line)
  end

  def test_map_parameter_read
    a = analyse("mapkit.rb")
    value = hover_text(a, "scores.fetch", 2)
    assert_includes value, "scores: T::Hash[String, Integer (i64)]"
    assert_includes value, "block parameter"
  end

  def test_map_field_declaration
    a = analyse("mapkit.rb")
    value = hover_text(a, "field :scores", 8)
    assert_includes value, "field :scores -> T::Hash[String, Integer (i64)]"
    assert_includes hover_text(a, "field :groups", 8), "T::Hash[String, T::Array[String]]"
  end

  def test_inlay_hint_for_a_map_block_parameter
    a = analyse("mapkit.rb")
    line0 = a.lines.index { |l| l.include?("do |scores, name|") }
    hints = RmcpDsl::Lsp::InlayHints.for(a, line0, line0)
    assert_equal [": T::Hash[String, Integer (i64)]", ": String"], hints.map { |h| h["label"] }
    assert_equal a.lines[line0].index("scores") + 6, hints.first["position"]["character"]
  end

  def test_inlay_hints_respect_the_line_range
    a = analyse("formkit.rb")
    assert_equal [], RmcpDsl::Lsp::InlayHints.for(a, 0, 3)
  end

  def test_params_declaration_lists_its_fields
    a = analyse("formkit.rb")
    value = hover_text(a, "params :Address", 2)
    assert_includes value, "params Address"
    assert_includes value, "city: String"
    assert_includes value, "zip: String"
    refute_includes value, "email"
    assert_equal value, hover_text(a, ":Address do", 3), "the name token answers like the call name"
  end

  def test_tool_declaration_shows_params_and_flags
    a = analyse("formkit.rb")
    value = hover_text(a, "tool :register", 1)
    assert_includes value, "tool register(RegisterParams)"
    assert_includes value, "read_only"
    assert_includes value, RmcpDsl::Docs.call("tool")
  end

  def test_tool_declaration_shows_its_output
    a = analyse("statkit.rb")
    assert_includes hover_text(a, "tool :stats", 1), "tool stats(TextParams) -> Stats"
  end

  def test_tool_flags_that_are_set
    a = analyse("notekit.rb")
    value = hover_text(a, "tool :delete_note", 1)[/```ruby\n(.*?)```/m, 1]
    assert_includes value, "destructive"
    assert_includes value, "idempotent"
    refute_includes value, "read_only"
  end

  def test_prompt_resource_server_and_transport_declarations
    a = analyse("notekit.rb")
    assert_includes hover_text(a, "prompt :summarize", 1), "prompt summarize(SummarizeParams)"
    value = hover_text(a, "resource :guide", 1)
    assert_includes value, "resource guide"
    assert_includes value, "notekit://guide"
    server = hover_text(a, "server \"notekit\"", 1)
    assert_includes server, "server"
    assert_includes server, "0.1.0"
    assert_includes hover_text(analyse("webkit.rb"), "transport :stdio", 2), "transport stdio"
  end

  def test_keyword_label_shows_its_documentation_and_value
    a = analyse("formkit.rb")
    h = RmcpDsl::Lsp::Hover.at(a, *spot(a, "read_only:", 2))
    value = h["contents"]["value"]
    assert_includes value, "read_only: true"
    assert_includes value, RmcpDsl::Docs.keyword(:tool, :read_only)
    line, col = spot(a, "read_only:")
    assert_equal({ "start" => { "line" => line, "character" => col }, "end" => { "line" => line, "character" => col + 9 } }, h["range"])
  end

  def test_whitespace_inside_a_block_and_strings_are_nil
    a = analyse("formkit.rb")
    assert_nil RmcpDsl::Lsp::Hover.at(a, *spot(a, "field :city", -1))
    assert_nil RmcpDsl::Lsp::Hover.at(a, *spot(a, "body do |email", -1))
    assert_nil RmcpDsl::Lsp::Hover.at(a, *spot(a, "Describe a registration", 3))
  end

  def test_declaration_hover_uses_utf16_columns_after_non_ascii
    text = <<~RB
      server "x", version: "0.1.0" do
        params :P do
          field :name, :string
        end
        tool :t, params: :P, description: "é😀", read_only: true do
          body do |name|
            name
          end
        end
        transport :stdio
      end
    RB
    a = RmcpDsl::Lsp::Analysis.new(File.join(EXAMPLES, "utf.rb"), text)
    line0 = a.lines.index { |l| l.include?("read_only") }
    col = a.lines[line0][0, a.lines[line0].index("read_only")].encode("UTF-16LE").bytesize / 2
    h = RmcpDsl::Lsp::Hover.at(a, line0, col + 1)
    assert h, a.diagnostics.inspect
    assert_includes h["contents"]["value"], "read_only: true"
    assert_equal col, h["range"]["start"]["character"]
    assert_equal col + 9, h["range"]["end"]["character"]
  end
end
