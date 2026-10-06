# frozen_string_literal: true

require "minitest/autorun"
require "rmcp_dsl"

class TestLspDefinition < Minitest::Test
  EXAMPLES = File.expand_path("../examples", __dir__)
  URI = "file:///work/examples/x.rmcp.rb"

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

  def definition(analysis, needle, offset = 0, nth: 0)
    RmcpDsl::Lsp::Definition.at(analysis, *spot(analysis, needle, offset, nth: nth), URI)
  end

  # The Location of `word` on the first line containing `line_text`.
  def expected(analysis, line_text, word)
    line0 = analysis.lines.index { |l| l.include?(line_text) }
    flunk "no line #{line_text.inspect}" unless line0
    first = analysis.lines[line0].index(word)
    { "uri" => URI,
      "range" => { "start" => { "line" => line0, "character" => first }, "end" => { "line" => line0, "character" => first + word.length } } }
  end

  def test_params_keyword_goes_to_the_params_declaration
    a = analyse("webkit.rmcp.rb")
    assert_equal expected(a, "params :UrlParams do", "UrlParams"), definition(a, "params: :UrlParams", 11)
  end

  def test_output_keyword_goes_to_the_output_declaration
    a = analyse("statkit.rmcp.rb")
    assert_equal expected(a, "output :Stats do", "Stats"), definition(a, "output: :Stats", 11)
  end

  def test_result_call_goes_to_the_output_declaration
    a = analyse("statkit.rmcp.rb")
    assert_equal expected(a, "output :Counts do", "Counts"), definition(a, "result(:Counts", 9)
  end

  def test_nested_field_type_goes_to_the_declaration
    a = analyse("formkit.rmcp.rb")
    assert_equal expected(a, "params :Address do", "Address"), definition(a, "field :address, :Address", 18)
    b = analyse("statkit.rmcp.rb")
    assert_equal expected(b, "output :Counts do", "Counts"), definition(b, "field :counts, :Counts", 17)
  end

  def test_helper_call_goes_to_the_helper_name
    a = analyse("webkit.rmcp.rb")
    assert_equal expected(a, "helper :checked_host,", "checked_host"), definition(a, "host = checked_host(url)", 10)
  end

  def test_unknown_names_and_other_places_answer_nil
    a = analyse("webkit.rmcp.rb")
    assert_nil definition(a, "use_bindings :html", 15)
    assert_nil definition(a, "Url.valid?(url)", 1)
    assert_nil definition(a, "host = checked_host(url)", 1)
    assert_nil RmcpDsl::Lsp::Definition.at(RmcpDsl::Lsp::Analysis.new("x.rmcp.rb", "x :Nowhere\n"), 0, 5, URI)
    assert_nil RmcpDsl::Lsp::Definition.at(a, 0, 0, URI)
  end

  def test_utf16_columns_after_non_ascii
    text = <<~RB
      server "x", version: "0.1.0" do
        params :P do
          field :name, :string
        end
        tool :t, description: "é😀", params: :P, read_only: true do
          body do |name|
            name
          end
        end
        transport :stdio
      end
    RB
    a = RmcpDsl::Lsp::Analysis.new(File.join(EXAMPLES, "utf.rb"), text)
    line0 = a.lines.index { |l| l.include?("params: :P") }
    col = a.lines[line0][0, a.lines[line0].index("params: :P") + 9].encode("UTF-16LE").bytesize / 2
    found = RmcpDsl::Lsp::Definition.at(a, line0, col, URI)
    assert found, a.diagnostics.inspect
    assert_equal({ "start" => { "line" => 1, "character" => 10 }, "end" => { "line" => 1, "character" => 11 } }, found["range"])
  end

  def test_outline_of_formkit
    a = analyse("formkit.rmcp.rb")
    outline = RmcpDsl::Lsp::Outline.for(a)
    assert_equal 1, outline.size
    server = outline.first
    assert_equal ["formkit", 2, "0.1.0"], [server["name"], server["kind"], server["detail"]]
    assert_equal %w[Address RegisterParams register BranchParams summarize stdio], server["children"].map { |c| c["name"] }
    assert_equal [23, 23, 12, 23, 12, 14], server["children"].map { |c| c["kind"] }
    address = server["children"].first
    assert_equal %w[city zip], address["children"].map { |c| c["name"] }
    assert_equal [8, 8], address["children"].map { |c| c["kind"] }
    assert_equal ["String", "String"], address["children"].map { |c| c["detail"] }
    assert_equal({ "start" => { "line" => 3, "character" => 10 }, "end" => { "line" => 3, "character" => 17 } }, address["selectionRange"])
    assert_equal 3, address["range"]["start"]["line"]
    assert_equal 6, address["range"]["end"]["line"]
    assert_equal "(RegisterParams)", server["children"][2]["detail"]
  end

  def test_outline_ranges_contain_their_selection_ranges
    %w[formkit.rmcp.rb webkit.rmcp.rb notekit.rmcp.rb statkit.rmcp.rb].each do |name|
      walk(RmcpDsl::Lsp::Outline.for(analyse(name))) do |sym|
        s = sym["range"]
        sel = sym["selectionRange"]
        assert_operator ([s["start"]["line"], s["start"]["character"]] <=> [sel["start"]["line"], sel["start"]["character"]]), :<=, 0, "#{name} #{sym["name"]}"
        assert_operator ([sel["end"]["line"], sel["end"]["character"]] <=> [s["end"]["line"], s["end"]["character"]]), :<=, 0, "#{name} #{sym["name"]}"
      end
    end
  end

  def walk(symbols, &block)
    symbols.each do |sym|
      block.call(sym)
      walk(sym["children"] || [], &block)
    end
  end

  def test_outline_of_webkit_has_helpers_and_statkit_outputs
    names = RmcpDsl::Lsp::Outline.for(analyse("webkit.rmcp.rb")).first["children"].select { |c| c["kind"] == 12 }.map { |c| c["name"] }
    assert_includes names, "checked_host"
    assert_includes names, "check_url"
    outputs = RmcpDsl::Lsp::Outline.for(analyse("statkit.rmcp.rb")).first["children"].select { |c| c["kind"] == 11 }
    assert_equal %w[Counts Stats], outputs.map { |c| c["name"] }
    assert_equal %w[items unique], outputs.first["children"].map { |c| c["name"] }.sort
  end
end
