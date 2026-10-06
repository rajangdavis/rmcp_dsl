# frozen_string_literal: true

# `rmcp_dsl rbi`: the Sorbet signatures for helpers, built from the compiler's IR, and the refusal of two
# files that declare one helper name with different signatures.
#
#   ruby -Ilib test/test_rbi.rb
require "minitest/autorun"
require "rmcp_dsl"
require "tmpdir"

class TestRbi < Minitest::Test
  def dsl(helpers, call)
    <<~RUBY
      server "t", version: "0.1.0" do
        params :P do
          field :text, :string
        end
      #{helpers.lines.map { |l| "  #{l}" }.join}
        tool :go, params: :P, description: "go" do
          body do |text|
            #{call}
          end
        end
        transport :stdio
      end
    RUBY
  end

  def write_all(sources)
    Dir.mktmpdir do |dir|
      paths = sources.map.with_index do |src, i|
        path = File.join(dir, "f#{i}.rb")
        File.write(path, src)
        path
      end
      yield paths
    end
  end

  def test_webkit_helpers
    text = RmcpDsl::Rbi.generate([File.expand_path("../examples/webkit.rmcp.rb", __dir__)])
    assert_match(/\A# typed: strict\n/, text)
    %w[ServerScope ToolScope PromptScope ResourceScope].each { |s| assert_includes text, "class #{s}\n" }
    assert_equal 4, text.scan("  sig { params(url: String).returns(T::Array[String]) }\n  def checked_addresses(url); end\n").size
    assert_equal 4, text.scan("  sig { params(url: String).returns(String) }\n  def checked_host(url); end\n").size
    assert_equal 4, text.scan("  sig { params(host: String, port: Integer, addrs: T::Array[String]).returns(String) }\n  def pin_arg(host, port, addrs); end\n").size
  end

  def test_nilable_return
    src = dsl(<<~H, "first_of(text.split(\",\")) || \"-\"")
      helper :first_of, args: [:string_list], returns: :string? do |items|
        items.first
      end
    H
    write_all([src]) do |paths|
      text = RmcpDsl::Rbi.generate(paths)
      assert_includes text, "  sig { params(items: T::Array[String]).returns(T.nilable(String)) }\n  def first_of(items); end\n"
    end
  end

  def test_nilable_argument_and_keyword_parameter
    src = dsl(<<~'H', 'endpoint(text, text.index("/"), sep: ",")')
      helper :endpoint, args: [:string, :i64?], returns: :string, kw: { sep: [:string, false] } do |host, port, sep: "http"|
        "#{sep}:#{host}:#{port || 0}"
      end
    H
    write_all([src]) do |paths|
      text = RmcpDsl::Rbi.generate(paths)
      assert_includes text, "  sig { params(host: String, port: T.nilable(Integer), sep: String).returns(String) }\n" \
                            "  def endpoint(host, port, sep: \"http\"); end\n"
    end
  end

  def test_type_mapping
    r = RmcpDsl::Rbi
    assert_equal "Integer", r.ruby_type("i32")
    assert_equal "Integer", r.ruby_type("i64")
    assert_equal "Float", r.ruby_type("f64")
    assert_equal "T::Boolean", r.ruby_type("bool")
    assert_equal "T::Array[Integer]", r.ruby_type("i64s")
    assert_equal "T::Array[Float]", r.ruby_type("f64s")
    assert_equal "T.nilable(T::Array[Float])", r.ruby_type("of64s")
    assert_equal "T.nilable(Integer)", r.ruby_type("oi64")
    assert_equal "T.nilable(T::Boolean)", r.ruby_type("obool")
    assert_equal "T.nilable(T::Array[String])", r.ruby_type("ostrs")
  end

  def test_same_signature_in_two_files_is_declared_once
    h = "helper :shout, args: [:string], returns: :string do |s|\n  s.upcase\nend\n"
    write_all([dsl(h, "shout(text)"), dsl(h, "shout(text)")]) do |paths|
      assert_equal 4, RmcpDsl::Rbi.generate(paths).scan("def shout(s); end").size
    end
  end

  def test_conflicting_signatures_name_both_files
    a = "helper :size_of, args: [:string], returns: :i64 do |s|\n  s.length\nend\n"
    b = "helper :size_of, args: [:string], returns: :string do |s|\n  s\nend\n"
    write_all([dsl(a, "size_of(text).to_s"), dsl(b, "size_of(text)")]) do |paths|
      e = assert_raises(RmcpDsl::CompileError) { RmcpDsl::Rbi.generate(paths) }
      assert_includes e.message, "helper `size_of`"
      assert_includes e.message, paths[0]
      assert_includes e.message, paths[1]
    end
  end
end
