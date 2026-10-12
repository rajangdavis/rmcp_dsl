# frozen_string_literal: true

# Rust::Str(s) in a body: a string with Rust `str` behaviour (rmcp-for-blender gaps #34). Ruby's own
# String methods are untouched; the Rust ones are opted into by the wrapper and left with `to_s`.
#
#   ruby -Ilib test/test_rust_str.rb              # the emitted Rust and the refusals
#   RMCP_CARGO=1 ruby -Ilib test/test_rust_str.rb # also cargo-checks the crate (make test-ruby-rust)
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "rmcp_dsl"

class TestRustStr < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)

  def source(body)
    <<~RB
      server "s", version: "0.1.0" do
        params :P do
          field :text, :string
        end

        tool :t, params: :P, description: "d" do
          body do |text|
      #{body}
          end
        end

        transport :stdio
      end
    RB
  end

  def with_source(body)
    Dir.mktmpdir("rust-str") do |dir|
      file = File.join(dir, "s.rmcp.rb")
      File.write(file, source(body))
      yield file
    end
  end

  def check(body)
    with_source(body) do |file|
      out, err, status = Open3.capture3(RbConfig.ruby, EXE, "check", file)
      yield status, out + err
    end
  end

  GOOD = <<~'RB'
    t = Rust::Str(text).trim
    low = t.to_lowercase.replace("a", "b")
    parts = low.split(",")
    rows = Rust::Str(text).lines
    flag = t.contains("x") && t.starts_with?("y")
    "#{low.to_s} #{parts.length} #{rows.length} #{flag} #{t.len} #{Rust::Str(text).to_uppercase.to_s}"
  RB

  def test_the_wrapper_compiles_to_rust_str_methods
    with_source(GOOD) do |file|
      _out, err, status = Open3.capture3(RbConfig.ruby, EXE, "check", file)
      assert status.success?, err
      main = RmcpDsl::Emit.files(RmcpDsl.read(file), file)["src/main.rs"]
      assert_includes main, ".trim().to_string()"
      assert_includes main, ".to_lowercase()"
      assert_includes main, ".to_uppercase()"
      assert_includes main, ".replace("
      assert_includes main, ".lines().map("
      assert_includes main, ".contains("
      assert_includes main, ".starts_with("
    end
  end

  def test_strip_is_trim_with_its_notice
    check("Rust::Str(text).strip.to_s\n") do |status, out|
      assert status.success?, out
      assert_includes out, "N-STR-STRIP-RUST"
    end
  end

  def test_ruby_strip_is_still_ruby_strip
    with_source("text.strip\n") do |file|
      main = RmcpDsl::Emit.files(RmcpDsl.read(file), file)["src/main.rs"]
      assert_includes main, "trim_matches("
    end
  end

  def test_an_unknown_method_is_refused_and_names_the_choices
    check("Rust::Str(text).bogus.to_s\n") do |status, out|
      refute status.success?
      assert_includes out, "unsupported method `bogus` on Rust::Str"
    end
  end

  def test_a_wrong_argument_count_is_refused
    check("Rust::Str(text).replace(\"a\").to_s\n") do |status, out|
      refute status.success?
      assert_includes out, "Rust::Str `replace` takes 2 arguments, got 1"
    end
  end

  def test_the_wrapper_takes_a_string
    check("Rust::Str(3).to_s\n") do |status, out|
      refute status.success?
      assert_includes out, "Rust::Str wraps a string"
    end
  end

  def test_the_result_must_leave_the_wrapper_with_to_s
    check("Rust::Str(text).trim\n") do |status, out|
      refute status.success?
      assert_includes out, "body must return a string, got Rust::Str"
    end
  end

  def test_the_emitted_crate_compiles
    skip "set RMCP_CARGO=1 to cargo-check the emitted crate (make test-ruby-rust)" unless ENV["RMCP_CARGO"]
    with_source(GOOD) do |file|
      out = File.join(File.dirname(file), "out")
      _o, err, status = Open3.capture3(RbConfig.ruby, EXE, "build", file, "-o", out)
      assert status.success?, err
      _o, err, status = Open3.capture3("cargo", "check", "-q", chdir: out)
      assert status.success?, "cargo check refused the emitted crate:\n#{err}"
    end
  end
end