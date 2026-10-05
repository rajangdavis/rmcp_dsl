# frozen_string_literal: true

# Completion works on text that does not compile: the cursor is marked with <C> and the rest of that line is
# dropped, as an editor would have it mid-typing.
#
#   ruby -Ilib test/test_lsp_completion.rb
require "minitest/autorun"
require "rmcp_dsl"

class TestLspCompletion < Minitest::Test
  C = "<C>"

  # text with one <C>: the text before the marker plus the following lines; the line's own tail is dropped.
  def complete(source, path: "t.rmcp.rb")
    before, after = source.split(C, 2)
    rest = after.to_s.sub(/\A[^\n]*/, "")
    text = before + rest
    row = before.split("\n", -1).size - 1
    col = before.split("\n", -1).last.to_s.encode("UTF-16LE").bytesize / 2
    analysis = RmcpDsl::Lsp::Analysis.new(path, text)
    RmcpDsl::Lsp::Completion.at(analysis, row, col)
  end

  def labels(source) = complete(source).map { |i| i["label"] }

  HEADER = <<~RUBY
    server "t", version: "0.1.0" do
      params :Address do
        field :city, :string
        field :zip, :i32
      end

      params :TextParams do
        field :text, :string
        field :n, :i32
        field :tags, :string_list
        field :maybe, :string, optional: true
        field :addr, :Address
      end

      output :Out do
        field :total, :i64
      end

  RUBY

  def in_body(code)
    "#{HEADER}  tool :slug, params: :TextParams, description: \"d\" do\n    body do |text, n, tags, maybe, addr|\n      #{code}\n    end\n  end\nend\n"
  end

  # --- receivers ------------------------------------------------------------------------------------------

  def test_string_receiver_offers_string_methods_only
    got = labels(in_body("text.#{C}"))
    assert_includes got, "upcase"
    assert_includes got, "split"
    assert_includes got, "gsub"
    refute_includes got, "map"
    refute_includes got, "times"
    refute_includes got, "nil?"
  end

  def test_method_detail_is_the_return_type
    split = complete(in_body("text.#{C}")).find { |i| i["label"] == "split" }
    assert_equal "→ T::Array[String]", split["detail"]
    assert_equal 2, split["kind"]
  end

  def test_receiver_prefix_filters
    assert_equal %w[split], labels(in_body("text.sp#{C}"))
  end

  def test_list_receivers
    got = labels(in_body("tags.#{C}"))
    assert_includes got, "map"
    assert_includes got, "join"
    refute_includes got, "upcase"
    chained = labels(in_body("text.split(\",\").#{C}"))
    assert_includes chained, "join"
    refute_includes chained, "strip"
  end

  def test_indexing_a_list_gives_a_nilable
    got = labels(in_body("text.split(\",\")[0].#{C}"))
    assert_equal %w[nil? to_s], got.sort
  end

  def test_integer_float_and_nilable_receivers
    ints = labels(in_body("n.#{C}"))
    assert_includes ints, "times"
    refute_includes ints, "upcase"
    assert_equal %w[nil? to_s], labels(in_body("maybe.#{C}")).sort
    assert_equal %w[to_s], labels(in_body("1.5.#{C}"))
  end

  def test_object_receiver_offers_its_fields
    items = complete(in_body("addr.#{C}"))
    assert_equal %w[city zip], items.map { |i| i["label"] }
    assert_equal [5, 5], items.map { |i| i["kind"] }
    assert_equal "Integer (i32)", items.last["detail"]
  end

  def test_unknown_receiver_offers_every_method_labelled_by_type
    items = complete(in_body("mystery.#{C}"))
    got = items.map { |i| i["label"] }
    assert_includes got, "upcase"
    assert_includes got, "join"
    assert_includes got, "times"
    upcase = items.find { |i| i["label"] == "upcase" }
    assert_includes upcase["detail"], "String"
  end

  def test_local_assigned_from_a_chain
    got = labels(in_body("parts = text.split(\",\")\n      parts.#{C}"))
    assert_includes got, "join"
    refute_includes got, "upcase"
  end

  def test_block_parameter_gets_the_element_type
    got = labels(in_body("text.split.select { |w| w.#{C}"))
    assert_includes got, "start_with?"
    refute_includes got, "join"
  end

  def test_non_ascii_line
    got = labels(in_body("s = \"日本語😀\" + text.up#{C}"))
    assert_equal %w[upcase], got
  end

  # --- maps -------------------------------------------------------------------------------------------------

  MAP_HEADER = <<~RUBY
    server "t", version: "0.1.0" do
      params :MapParams do
        field :text, :string
        field :scores, map(:i64)
        field :names, map(:string)
        field :groups, map(list(:string))
        field :ratio, map(:f64)
        field :extra, map(:string), optional: true
        field :words, list(:string)
      end

  RUBY

  def in_map_body(code)
    "#{MAP_HEADER}  tool :m, params: :MapParams, description: \"d\" do\n    body do |text, scores, names, groups, ratio, extra, words|\n      #{code}\n    end\n  end\nend\n"
  end

  def detail(source, label) = complete(source).find { |i| i["label"] == label }&.fetch("detail")

  def test_map_receiver_offers_exactly_the_compilers_methods
    assert_equal RmcpDsl::Body::MAP_ARITY.keys.map(&:to_s).sort, labels(in_map_body("scores.#{C}")).sort
  end

  def test_map_method_details_show_the_return_type_for_the_value_type
    src = in_map_body("scores.#{C}")
    assert_equal "→ Integer (i64)", detail(src, "fetch")
    assert_equal "→ T.nilable(Integer (i64))", detail(src, "[]")
    assert_equal "→ T::Array[String]", detail(src, "keys")
    assert_equal "→ T::Array[Integer (i64)]", detail(src, "values")
    assert_equal "→ Integer (i64)", detail(src, "size")
    assert_equal "→ Integer (i64)", detail(src, "length")
    assert_equal "→ T::Boolean", detail(src, "key?")
    assert_equal "→ T::Boolean", detail(src, "empty?")
    assert_equal "→ T::Hash[String, Integer (i64)]", detail(src, "merge")
    assert_equal "→ T::Array[String]", detail(in_map_body("names.#{C}"), "values")
    assert_equal "→ Float", detail(in_map_body("ratio.#{C}"), "fetch")
  end

  def test_map_values_has_a_return_type_only_for_strings_and_integers
    assert_equal "(0 args)", detail(in_map_body("ratio.#{C}"), "values")
    assert_equal "(0 args)", detail(in_map_body("groups.#{C}"), "values")
    assert_equal "→ T::Array[String]", detail(in_map_body("groups.#{C}"), "fetch")
  end

  def test_a_nilable_map_offers_only_nil_check
    assert_equal %w[nil?], labels(in_map_body("extra.#{C}"))
  end

  def test_map_chains_and_locals
    assert_includes labels(in_map_body("scores.merge(names).#{C}")), "fetch"
    assert_includes labels(in_map_body("scores.keys.#{C}")), "join"
    assert_includes labels(in_map_body("scores.values.#{C}")), "sum"
    assert_equal %w[nil? to_s], labels(in_map_body("scores[\"a\"].#{C}")).sort
    assert_includes labels(in_map_body("copy = scores\n      copy.#{C}")), "fetch"
  end

  def test_map_literals
    assert_equal "→ Integer (i64)", detail(in_map_body("{ \"a\" => 1 }.#{C}"), "fetch")
    assert_equal "→ String", detail(in_map_body("{ \"a\" => \"b\", \"c\" => \"d\" }.#{C}"), "fetch")
    assert_equal "→ Float", detail(in_map_body("m = { \"a\" => 1.5 }\n      m.#{C}"), "fetch")
    assert_equal "→ T::Boolean", detail(in_map_body("m = { \"a\" => true }\n      m.#{C}"), "fetch")
    assert_equal "→ T::Array[String]", detail(in_map_body("m = { \"a\" => words }\n      m.#{C}"), "fetch")
    assert_includes labels(in_map_body("m = {}\n      m.#{C}")), "keys"
    assert_equal "(1..2 args)", detail(in_map_body("m = {}\n      m.#{C}"), "fetch")
  end

  def test_tally_on_a_list_of_strings
    assert_equal "→ T::Hash[String, Integer (i64)]", detail(in_map_body("words.#{C}"), "tally")
    assert_equal "→ T::Hash[String, Integer (i64)]", detail(in_map_body("text.split(\",\").#{C}"), "tally")
    assert_includes labels(in_map_body("words.tally.#{C}")), "fetch"
    assert_equal "→ Integer (i64)", detail(in_map_body("counts = words.tally\n      counts.#{C}"), "fetch")
    assert_includes labels(in_map_body("1.upto(3).#{C}")), "sum"
    refute_includes labels(in_map_body("1.upto(3).#{C}")), "tally"
  end

  def test_a_map_parameter_is_listed_with_its_type
    items = complete("#{MAP_HEADER}  tool :m, params: :MapParams, description: \"d\" do\n    body do |#{C}")
    scores = items.find { |i| i["label"] == "scores" }
    assert_equal "T::Hash[String, Integer (i64)]", scores["detail"]
    assert_equal "T.nilable(T::Hash[String, String])", items.find { |i| i["label"] == "extra" }["detail"]
    assert_equal "T::Hash[String, T::Array[String]]", items.find { |i| i["label"] == "groups" }["detail"]
    assert_equal "T::Array[String]", items.find { |i| i["label"] == "words" }["detail"]
  end

  # --- the type position of a field ---------------------------------------------------------------------------

  def test_field_type_offers_map_and_list_snippets_with_documentation
    items = complete("#{HEADER}  params :More do\n    field :x, #{C}")
    names = items.map { |i| i["label"] }
    assert_includes names, "map("
    assert_includes names, "list("
    %w[:string :i32 :string_list :i64_list :Address].each { |n| assert_includes names, n }
    map = items.find { |i| i["label"] == "map(" }
    assert_equal 2, map["insertTextFormat"]
    assert_equal "map($0)", map["insertText"]
    assert_equal 15, map["kind"]
    assert_match(/map/i, map["documentation"])
    assert_match(/list/i, items.find { |i| i["label"] == "list(" }["documentation"])
    assert_equal %w[map(], labels("#{HEADER}  params :More do\n    field :x, ma#{C}")
    assert_includes labels("#{HEADER}  output :Res do\n    field :x, li#{C}"), "list("
  end

  def test_inside_map_the_value_types_and_list_only
    got = labels("#{HEADER}  params :More do\n    field :x, map(#{C}")
    assert_equal %w[:string :i64 :f64 :bool list(], got
    assert_equal %w[:i64], labels("#{HEADER}  params :More do\n    field :x, map(:i#{C}")
    assert_equal %w[:string :i64 :f64 :bool], labels("#{HEADER}  params :More do\n    field :x, map(:#{C}")
    assert_equal %w[:string :i64], labels("#{HEADER}  params :More do\n    field :x, map(list(#{C}")
    assert_equal %w[:string :i64], labels("#{HEADER}  output :Res do\n    field :x, map(list(:#{C}")
  end

  def test_inside_list_only_string_and_i64
    assert_equal %w[:string :i64], labels("#{HEADER}  params :More do\n    field :x, list(#{C}")
    assert_equal %w[:string], labels("#{HEADER}  params :More do\n    field :x, list(:st#{C}")
    refute_includes labels("#{HEADER}  params :More do\n    field :x, list(#{C}"), "map("
  end

  def test_a_map_field_declared_after_options_still_completes_keywords
    assert_includes labels("#{HEADER}  params :More do\n    field :x, map(:i64), #{C}"), "description:"
  end

  def test_mapkit_map_parameter_completion
    # the line that reads scores sits in a string, where nothing is offered, so it is replaced by `scores.`
    text = example("mapkit").lines.map { |l| l.include?("scores.fetch") ? "      scores.\n" : l }.join
    row = text.lines.index("      scores.\n")
    got = RmcpDsl::Lsp::Completion.at(RmcpDsl::Lsp::Analysis.new("e.rmcp.rb", text), row, 13).map { |i| i["label"] }
    assert_includes got, "fetch"
    assert_includes got, "keys"
  end

  # --- names in scope ---------------------------------------------------------------------------------------

  def test_block_parameters_come_from_the_params_declaration
    src = "#{HEADER}  tool :slug, params: :TextParams, description: \"d\" do\n    body do |#{C}"
    assert_equal %w[text n tags maybe addr], labels(src)
    assert_equal %w[tags], labels(src.sub(C, "text, n, ta#{C}"))
    refute_includes labels(src.sub(C, "text, #{C}")), "text"
    assert_includes labels(src.sub(C, "text, #{C}")), "n"
  end

  def test_locals_and_parameters_in_scope
    got = labels(in_body("y = n + 1\n      #{C}"))
    assert_includes got, "text"
    assert_includes got, "y"
    assert_includes got, "raise"
    assert_equal %w[text], labels(in_body("te#{C}"))
  end

  # --- keyword arguments ------------------------------------------------------------------------------------

  def test_keywords_of_a_tool_required_first
    items = complete("#{HEADER}  tool :x, #{C}")
    names = items.map { |i| i["label"] }
    assert_equal %w[params: description:], names.first(2)
    assert_includes names, "read_only:"
    assert_includes names, "output:"
    desc = items.find { |i| i["label"] == "description:" }
    assert_equal 'description: "${1}"', desc["insertText"]
    assert_equal 2, desc["insertTextFormat"]
  end

  def test_given_keywords_are_not_offered_again
    names = labels("#{HEADER}  tool :x, params: :TextParams, #{C}")
    refute_includes names, "params:"
    assert_includes names, "description:"
    assert_equal %w[description:], labels("#{HEADER}  tool :x, params: :TextParams, desc#{C}")
  end

  def test_keywords_continue_on_the_next_line
    names = labels("#{HEADER}  tool :x, params: :TextParams,\n    #{C}")
    assert_includes names, "description:"
    refute_includes names, "params:"
  end

  # --- symbol values ----------------------------------------------------------------------------------------

  def test_field_types_include_nested_params
    got = labels("#{HEADER}  params :More do\n    field :x, #{C}")
    assert_includes got, ":string"
    assert_includes got, ":i32"
    assert_includes got, ":string_list"
    assert_includes got, ":i64_list"
    assert_includes got, ":Address"
    refute_includes got, ":More"
  end

  def test_symbol_prefix_filters_and_drops_the_colon_it_has
    items = complete("#{HEADER}  params :More do\n    field :x, :s#{C}")
    assert_equal %w[:string :string_list], items.map { |i| i["label"] }
    assert_equal "string", items.first["insertText"]
    plain = complete("#{HEADER}  params :More do\n    field :x, s#{C}")
    assert_equal ":string", plain.first["insertText"]
  end

  def test_formats
    got = labels("#{HEADER}  params :More do\n    field :x, :string, format: :#{C}")
    assert_includes got, ":uri"
    assert_includes got, ":date_time"
    refute_includes got, ":string"
  end

  def test_helper_types
    assert_includes labels("#{HEADER}  helper :h, args: [#{C}"), ":string_list"
    assert_includes labels("#{HEADER}  helper :h, args: [:string, :#{C}"), ":i64"
    refute_includes labels("#{HEADER}  helper :h, args: [#{C}"), ":string?"
    returns = labels("#{HEADER}  helper :h, args: [:string], returns: :#{C}")
    assert_includes returns, ":string?"
    assert_includes returns, ":i64_list?"
  end

  def test_transport_and_message_roles
    assert_equal %w[:stdio :http], labels("#{HEADER}  transport #{C}")
    assert_equal %w[:user :assistant], labels("#{HEADER}  prompt :p, params: :TextParams, description: \"d\" do\n    message #{C}")
  end

  def test_params_and_output_names_have_the_right_kind
    params = labels("#{HEADER}  tool :x, params: :#{C}")
    assert_equal %w[:Address :TextParams], params.sort
    outs = labels("#{HEADER}  tool :x, params: :TextParams, output: :#{C}")
    assert_equal %w[:Out], outs
  end

  def test_booleans
    assert_equal %w[true false], labels("#{HEADER}  tool :x, params: :TextParams, read_only: #{C}")
  end

  def test_keyword_and_declaration_items_carry_markdown_documentation
    kw = complete("#{HEADER}  tool :x, #{C}").find { |i| i["label"] == "read_only:" }
    assert_equal({ "kind" => "markdown", "value" => RmcpDsl::Docs.keyword(:tool, :read_only) }, kw["documentation"])
    assert_equal "true or false", kw["detail"]
    tool = complete("server \"x\", version: \"1\" do\n  #{C}").find { |i| i["label"] == "tool" }
    assert_equal RmcpDsl::Docs.call(:tool), tool["documentation"]["value"]
    assert_equal "A tool the server offers", tool["detail"]
  end

  def test_fixed_string_choices_are_offered_in_a_list
    res = "#{HEADER}  resource :r, uri: \"a://b\", audience: ["
    assert_equal %w["user" "assistant"], labels("#{res}#{C}")
    assert_equal %w[user assistant], labels("#{res}\"#{C}")
    assert_equal %w[assistant], labels("#{res}\"user\", \"#{C}")
    assert_equal %w[assistant], labels("#{res}\"a#{C}")
    assert_equal %w[assistant], labels("#{HEADER}  resource :r, uri: \"a://b\",\n    audience: [\"user\", \"#{C}")
    assert_empty labels("#{HEADER}  resource :r, uri: \"a://b\", title: [\"#{C}")
  end

  # --- declarations -----------------------------------------------------------------------------------------

  def test_server_block_statements
    items = complete("server \"x\", version: \"1\" do\n  #{C}")
    names = items.map { |i| i["label"] }
    %w[params output tool helper prompt resource transport].each { |n| assert_includes names, n }
    refute_includes names, "field"
    refute_includes names, "body"
    tool = items.find { |i| i["label"] == "tool" }
    assert_equal 2, tool["insertTextFormat"]
    assert_includes tool["insertText"], "body do |"
    assert_equal %w[tool], labels("server \"x\", version: \"1\" do\n  to#{C}")
  end

  def test_top_level_offers_server
    assert_equal %w[server], labels("#{C}")
  end

  def test_params_and_output_blocks_offer_field
    assert_equal %w[field], labels("server \"x\", version: \"1\" do\n  params :P do\n    #{C}")
    assert_equal %w[field], labels("server \"x\", version: \"1\" do\n  output :P do\n    #{C}")
  end

  def test_tool_prompt_and_resource_blocks
    head = "server \"x\", version: \"1\" do\n"
    assert_equal %w[body], labels("#{head}  tool :t, params: :P, description: \"d\" do\n    #{C}")
    assert_equal %w[body message], labels("#{head}  prompt :t, params: :P, description: \"d\" do\n    #{C}")
    assert_equal %w[body], labels("#{head}  resource :t, uri: \"u\" do\n    #{C}")
  end

  def test_nothing_is_offered_inside_strings_and_comments
    assert_empty labels("#{HEADER}  tool :x, description: \"foo #{C}")
    assert_empty labels(in_body("# text.#{C}"))
  end

  # --- robustness -------------------------------------------------------------------------------------------

  def test_garbage_never_raises
    junk = ["", "\n\n", "end end end", "do |", "} ) ] .", "server do do do\n  tool", "\u0000ÿ\u{1F600}.", "x = = =\n.",
            "body do |a,\n  a.", "tool :x, params: , , ,", "helper :h, args: [[[", "\"unterminated", "{ |w| w.", "..."]
    junk.each do |text|
      analysis = RmcpDsl::Lsp::Analysis.new("g.rmcp.rb", text)
      lines = [text.split("\n", -1).size + 2, 1].max
      lines.times do |row|
        [0, 1, 3, 40].each do |col|
          out = RmcpDsl::Lsp::Completion.at(analysis, row, col)
          assert_kind_of Array, out
        end
      end
    end
    assert_kind_of Array, RmcpDsl::Lsp::Completion.at(RmcpDsl::Lsp::Analysis.new("g.rmcp.rb", "x"), -3, -5)
  end

  # --- real examples ----------------------------------------------------------------------------------------

  def example(name) = File.read(File.expand_path("../examples/#{name}.rb", __dir__))

  def cut_at(text, needle)
    line = text.lines.index { |l| l.include?(needle) } or flunk "no line with #{needle}"
    row = line
    col = text.lines[line].index(needle) + needle.length
    text = (text.lines[0...line] + [text.lines[line][0...col]] + text.lines[(line + 1)..]).join
    [RmcpDsl::Lsp::Analysis.new("e.rmcp.rb", text), row, col]
  end

  def test_listkit_chain
    analysis, row, col = cut_at(example("listkit"), 'text.split(",").')
    got = RmcpDsl::Lsp::Completion.at(analysis, row, col).map { |i| i["label"] }
    assert_includes got, "join"
    refute_includes got, "upcase"
  end

  def test_webkit_helper_block_parameter
    analysis, row, col = cut_at(example("webkit"), 'addrs.find { |a| !a.')
    got = RmcpDsl::Lsp::Completion.at(analysis, row, col).map { |i| i["label"] }
    assert_includes got, "include?"
    assert_includes got, "start_with?"
  end

  def test_every_position_of_every_example_answers_without_raising
    Dir[File.expand_path("../examples/*.rb", __dir__)].each do |path|
      text = File.read(path)
      analysis = RmcpDsl::Lsp::Analysis.new(path, text)
      analysis.lines.each_with_index do |line, row|
        (0..line.length).step(5) do |col|
          out = RmcpDsl::Lsp::Completion.at(analysis, row, col)
          assert out.all? { |i| i["label"].is_a?(String) && i["kind"].is_a?(Integer) }, "#{path}:#{row + 1}:#{col}"
        end
      end
    end
  end

  def test_method_tables_are_known_to_the_compiler
    tables = [RmcpDsl::Lsp::Completion::STRING_METHODS, RmcpDsl::Lsp::Completion::INT_METHODS, RmcpDsl::Lsp::Completion::LIST_RET]
    names = tables.flat_map(&:keys) - %w[times upto downto nil?]
    assert_empty names - RmcpDsl::Body::ALLOWED_METHODS
  end
end
