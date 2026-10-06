# frozen_string_literal: true

require "minitest/autorun"
require "rmcp_dsl"

class TestLspAnalysis < Minitest::Test
  EXAMPLES = File.expand_path("../examples", __dir__)

  def analyse(name, text = nil)
    path = File.join(EXAMPLES, name)
    RmcpDsl::Lsp::Analysis.new(path, text || File.read(path))
  end

  def test_position_ascii_is_the_identity_shifted_by_one
    assert_equal 4, RmcpDsl::Lsp::Position.to_lsp("abcdef", 5)
    assert_equal 5, RmcpDsl::Lsp::Position.from_lsp("abcdef", 4)
  end

  def test_position_counts_utf16_units_not_bytes
    line = "é = \"😀x\"" # é is 2 bytes, the emoji 4 bytes and 2 UTF-16 units
    x_byte_col = line[0, line.index("x")].bytesize + 1
    assert_equal line.index("x") + 1, RmcpDsl::Lsp::Position.to_lsp(line, x_byte_col) # 1 extra unit for the emoji
    assert_equal x_byte_col, RmcpDsl::Lsp::Position.from_lsp(line, line.index("x") + 1)
  end

  def test_position_past_the_end_lands_on_the_last_boundary
    assert_equal 4, RmcpDsl::Lsp::Position.from_lsp("abc", 99)
  end

  def test_a_good_file_has_types_and_no_diagnostics
    a = analyse("statkit.rmcp.rb")
    assert a.ok?, a.diagnostics.inspect
    refute_empty a.types
    assert(a.types.any? { |t| t[:kind] == "output" && t[:type] == "Stats" })
  end

  def test_unsaved_text_is_what_gets_compiled
    broken = File.read(File.join(EXAMPLES, "statkit.rmcp.rb")).sub("i.upcase", "i.upcas")
    a = analyse("statkit.rmcp.rb", broken)
    refute a.ok?
    d = a.diagnostics.last
    assert_match(/upcas/, d.message)
    assert_includes d.suggestions, "upcase"
    row = broken.split("\n")[d.line - 1]
    assert_includes row, "upcas" # the error is on the line of the mistake; it points at the start of the call
    assert_operator d.col, :<=, row.index("upcas") + 1
    assert_operator d.end_col, :>, d.col
  end

  def test_types_survive_a_mistake_further_down
    text = File.read(File.join(EXAMPLES, "formkit.rmcp.rb")).sub("tags.join", "tags.joinn")
    a = analyse("formkit.rmcp.rb", text)
    refute a.ok?
    assert(a.types.any? { |t| t[:kind] == "field" && t[:name] == "email" })
  end

  def test_declarations_record_the_call_its_keywords_and_the_name_token
    a = analyse("formkit.rmcp.rb")
    decls = a.types.select { |t| t[:kind] == "declaration" }
    params = decls.find { |t| t[:call] == "params" && t[:name] == "Address" }
    refute_nil params
    assert_equal "Address", a.line_text(params[:name_line])[(params[:name_col])...(params[:name_end_col] - 1)]
    tool = decls.find { |t| t[:call] == "tool" && t[:name] == "register" }
    assert_equal "RegisterParams", tool[:keywords]["params"]
    assert_equal "true", tool[:keywords]["read_only"]
    assert(decls.any? { |t| t[:call] == "server" && t[:name] == "formkit" })
    assert(decls.any? { |t| t[:call] == "transport" && t[:name] == "stdio" })
    refute(decls.any? { |t| %w[field helper output body].include?(t[:call]) })
  end

  def test_syntax_errors_become_diagnostics
    a = analyse("statkit.rmcp.rb", "server \"x\" do\n")
    refute a.ok?
    assert_match(/syntax error/, a.diagnostics.first.message)
  end

  def test_types_at_returns_the_narrowest_entry_first
    a = analyse("formkit.rmcp.rb")
    line = a.lines.index { |l| l.include?("address.city") } + 1
    col = a.line_text(line).index("address.city") + 1
    hits = a.types_at(line, col)
    refute_empty hits
    spans = hits.map { |t| [t[:end_line] - t[:line], t[:end_col] - t[:col]] }
    assert_equal spans.sort, spans
  end
end
