# frozen_string_literal: true

# "Did you mean" hints: RmcpDsl::Suggest, and the hints appended to compile errors (message and the
# structured "suggestions" array of `check --format json`).
#
#   ruby -Ilib test/test_hints.rb
require "minitest/autorun"
require "open3"
require "json"
require "rbconfig"
require "tmpdir"
require "rmcp_dsl"

class TestHints < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)
  S = RmcpDsl::Suggest

  def test_nearest_finds_a_typo
    assert_equal "upcase", S.nearest("upcas", %w[upcase downcase strip])
    assert_equal "description", S.nearest("descripton", %w[params description title])
  end

  def test_nearest_is_nil_when_nothing_is_close
    assert_nil S.nearest("zzzzzz", %w[upcase downcase strip])
    assert_nil S.nearest("x", %w[upcase])
  end

  def test_nearest_ignores_an_exact_match_and_takes_symbols
    assert_nil S.nearest(:strip, %w[strip])
    assert_equal "strip", S.nearest(:strp, [:strip, :split])
  end

  def test_ties_break_alphabetically_and_nearest_n_orders_by_distance
    assert_equal %w[ab ac], S.nearest_n("aa", %w[ac ab])
    assert_equal %w[size sizes], S.nearest_n("sizee", %w[sizes size])
    assert_equal 1, S.nearest_n("aa", %w[ab ac ad], 1).size
  end

  def test_distance
    assert_equal 0, S.distance("a", "a")
    assert_equal 1, S.distance("cat", "cut")
    assert_equal 3, S.distance("", "abc")
  end

  def check(src)
    Dir.mktmpdir do |dir|
      file = File.join(dir, "t.rb")
      File.write(file, src)
      out, = Open3.capture3(RbConfig.ruby, EXE, "check", file, "--format", "json")
      JSON.parse(out)
    end
  end

  def dsl(tool_extra: "", field: "field :text, :string", body: "text", params: "P")
    <<~RUBY
      server "t", version: "0.1.0" do
        params :P do
          #{field}
        end
        output :R do
          field :n, :i64
        end
        tool :x, params: :#{params}, description: "d"#{tool_extra} do
          body do |text|
            #{body}
          end
        end
        transport :stdio
      end
    RUBY
  end

  def test_unknown_method_suggests_and_lists
    err = check(dsl(body: "text.upcas"))["error"]
    assert_match(/\Aunsupported method `upcas` in body \(allowed: .*; did you mean `upcase`\?\z/, err["message"])
    assert_equal ["upcase"], err["suggestions"]
  end

  def test_unknown_field_type
    err = check(dsl(field: "field :text, :i65"))["error"]
    assert_includes err["message"], "is not a field type"
    assert_equal ["i64"], err["suggestions"]
  end

  def test_undeclared_params_lists_declared
    err = check(dsl(params: "Q"))["error"]
    assert_includes err["message"], "undeclared params `Q` (declared above: P); did you mean `P`?"
    assert_equal ["P"], err["suggestions"]
  end

  def test_unknown_block_parameter_lists_fields
    err = check(dsl(body: "text").sub("|text|", "|txt|"))["error"]
    assert_includes err["message"], "`txt` is not a field of the tool's params (fields: text); did you mean `text`?"
  end

  def test_result_field_typo
    err = check(dsl(tool_extra: ", output: :R", body: "result(:R, m: 1)"))["error"]
    assert_includes err["message"], "R has no field `m` (it has: n); did you mean `n`?"
    assert_equal ["n"], err["suggestions"]
  end

  def test_wrong_argument_count_shows_the_shape
    err = check(dsl(body: 'text.gsub("a")'))["error"]
    assert_includes err["message"], "`gsub` takes exactly two arguments"
    assert_includes err["message"], "expected `gsub(pattern, replacement)`"
    refute err.key?("suggestions")
  end

  def test_no_suggestions_key_without_a_near_name
    err = check(dsl(body: "text.zzzzzzzz"))["error"]
    refute err.key?("suggestions")
  end

  def test_unknown_keyword_and_call
    err = check(dsl(tool_extra: ', descripton: "x"'))["error"]
    assert_equal ["description"], err["suggestions"]
    err = check(dsl.sub("transport :stdio", "tranport :stdio"))["error"]
    assert_equal ["transport"], err["suggestions"]
  end
end
