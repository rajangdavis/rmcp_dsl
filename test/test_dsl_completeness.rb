# frozen_string_literal: true

# A guard for the editor side of the DSL. RmcpDsl::SIG is the one table the compiler, the generated skill and
# the editor read; when it gains a call or keyword, this fails until the sentence in lib/rmcp_dsl/docs.rb exists
# and completion offers the new name, so the DSL cannot grow without its documentation and its completion.
#
#   ruby -Ilib test/test_dsl_completeness.rb
require "minitest/autorun"
require "rmcp_dsl"

class TestDslCompleteness < Minitest::Test
  C = "<C>"
  PATH = File.expand_path("../examples/completeness.rmcp.rb", __dir__) # under examples/ so bindings resolve
  OPEN = "server \"t\", version: \"0.1.0\" do\n  params :P do\n    field :a, :string\n  end\n"
  SAMPLE = { str: "\"x\"", snake: ":x", camel: ":P", fieldtype: ":string", uint: "1", num: "1" }.freeze
  FIX = "add it in lib/rmcp_dsl/docs.rb (and, for completion, lib/rmcp_dsl/lsp/completion.rb)"

  # Source with one <C>: the text before it plus the following lines, as an editor would have it mid-typing.
  def complete(source)
    before, after = source.split(C, 2)
    text = before + after.to_s.sub(/\A[^\n]*/, "")
    lines = before.split("\n", -1)
    col = lines.last.to_s.encode("UTF-16LE").bytesize / 2
    RmcpDsl::Lsp::Completion.at(RmcpDsl::Lsp::Analysis.new(PATH, text), lines.size - 1, col)
  end

  def labels(source) = complete(source).map { |i| i["label"] }

  # A line that opens the call with its positional arguments given and `tail` as the next argument.
  def call_source(name, sig, kinds, tail)
    args = kinds.map { |k| k.is_a?(Array) ? ":#{k.first}" : SAMPLE.fetch(k) } + [tail]
    line = "#{name} #{args.join(', ')}"
    name == :server ? line : "#{OPEN}  #{line}"
  end

  def each_keyword
    RmcpDsl::SIG.each { |name, sig| sig[:kw].each { |kw, (kind, _)| yield name, sig, kw, kind } }
  end

  def test_every_call_has_a_sentence
    missing = RmcpDsl::SIG.keys.reject { |name| RmcpDsl::Docs.call(name) }
    assert_empty missing, "calls with no sentence in Docs::CALLS: #{missing.inspect}; #{FIX}"
  end

  def test_every_keyword_has_a_sentence
    missing = []
    each_keyword { |name, _, kw, _| missing << [name, kw] unless RmcpDsl::Docs.keyword(name, kw) }
    assert_empty missing, "keywords with no sentence in Docs::KEYWORDS: #{missing.inspect} (as `%i[call keyword] => \"A sentence.\"`); #{FIX}"
  end

  def test_docs_name_nothing_the_signature_table_lacks
    extra_calls = RmcpDsl::Docs::CALLS.keys - RmcpDsl::SIG.keys
    assert_empty extra_calls, "Docs::CALLS names calls SIG does not have: #{extra_calls.inspect}; remove them from docs.rb"
    known = RmcpDsl::SIG.flat_map { |name, sig| sig[:kw].keys.map { |kw| [name, kw] } }
    %i[KEYWORDS CHOICES].each do |table|
      extra = RmcpDsl::Docs.const_get(table).keys - known
      assert_empty extra, "Docs::#{table} names keywords SIG does not have: #{extra.inspect}; remove them from docs.rb"
    end
  end

  def test_sentences_are_one_plain_sentence
    all = RmcpDsl::Docs::CALLS.to_a + RmcpDsl::Docs::KEYWORDS.to_a
    bad = all.reject { |_, text| text.match?(/\A[A-Z]/) && text.end_with?(".") && text.length < 160 && !text.include?("\n") }
    assert_empty bad.map(&:first), "a sentence must start with a capital, end with a period and be under 160 characters: #{bad.map(&:first).inspect}"
  end

  def test_choices_name_keywords_that_are_not_already_symbol_lists
    each_keyword do |name, _, kw, kind|
      next unless RmcpDsl::Docs.choices(name, kw)

      refute_kind_of Array, kind, "[#{name}, #{kw}] is already a list of symbols in SIG; remove it from Docs::CHOICES"
    end
  end

  def test_completion_offers_every_keyword
    missing = []
    each_keyword do |name, sig, kw, _|
      got = labels(call_source(name, sig, sig[:pos], "#{kw}#{C}"))
      missing << [name, kw] unless got.include?("#{kw}:")
    end
    assert_empty missing, "Completion.at does not offer these [call, keyword] after `call args, kw`: #{missing.inspect}; check kw_items in lsp/completion.rb"
  end

  def test_completion_offers_every_call_in_its_context
    starts = { top: C, server: "server \"t\", version: \"0.1.0\" do\n  #{C}",
               params: "#{OPEN}  params :Q do\n    #{C}", output: "#{OPEN}  output :O do\n    #{C}",
               tool: "#{OPEN}  tool :t, params: :P, description: \"d\" do\n    #{C}",
               prompt: "#{OPEN}  prompt :t, params: :P, description: \"d\" do\n    #{C}",
               resource: "#{OPEN}  resource :r, uri: \"a://b\" do\n    #{C}" }
    contexts = RmcpDsl::SIG.values.flat_map { |sig| Array(sig[:in]) }.uniq
    unknown = contexts - starts.keys
    assert_empty unknown, "SIG has calls inside #{unknown.inspect}; add a statement-start text for it to `starts` in this test"
    missing = []
    contexts.each do |ctx|
      got = labels(starts.fetch(ctx))
      RmcpDsl::SIG.each { |name, sig| missing << [ctx, name] if Array(sig[:in]).include?(ctx) && !got.include?(name.to_s) }
    end
    assert_empty missing, "Completion.at does not offer these [context, call] at statement start: #{missing.inspect}; check statement_items in lsp/completion.rb"
  end

  def test_completion_offers_every_map_method_and_tally
    head = "#{OPEN}  params :M do\n    field :m, map(:i64)\n    field :w, list(:string)\n  end\n  tool :t, params: :M, description: \"d\" do\n    body do |m, w|\n      "
    got = labels("#{head}m.#{C}")
    missing = RmcpDsl::Body::MAP_ARITY.keys.map(&:to_s) - got
    assert_empty missing, "Completion.at does not offer these Body::MAP_ARITY methods on a map: #{missing.inspect}; check map_methods in lsp/completion.rb"
    assert_includes labels("#{head}w.#{C}"), "tally", "Completion.at does not offer tally on a list of strings; check LIST_RET in lsp/completion.rb"
  end

  def test_completion_offers_the_values_of_fixed_choice_keywords
    missing = []
    each_keyword do |name, sig, kw, kind|
      if kind.is_a?(Array)
        got = labels(call_source(name, sig, sig[:pos], "#{kw}: #{C}"))
        kind.each { |v| missing << [name, kw, v] unless got.include?(":#{v}") }
      elsif (values = RmcpDsl::Docs.choices(name, kw))
        bare = labels(call_source(name, sig, sig[:pos], "#{kw}: [#{C}"))
        quoted = labels(call_source(name, sig, sig[:pos], "#{kw}: [\"#{C}"))
        values.each { |v| missing << [name, kw, v] unless bare.include?("\"#{v}\"") && quoted.include?(v) }
      end
    end
    assert_empty missing, "Completion.at does not offer these [call, keyword, value]: #{missing.inspect}; check value_items and choice_items in lsp/completion.rb"
  end

  def test_completion_offers_the_values_of_fixed_choice_positionals
    missing = []
    RmcpDsl::SIG.each do |name, sig|
      sig[:pos].each_with_index do |kind, i|
        next unless kind.is_a?(Array)

        got = labels(call_source(name, sig, sig[:pos].first(i), C))
        kind.each { |v| missing << [name, i, v] unless got.include?(":#{v}") }
      end
    end
    assert_empty missing, "Completion.at does not offer these [call, position, value]: #{missing.inspect}; check value_items in lsp/completion.rb"
  end
end
