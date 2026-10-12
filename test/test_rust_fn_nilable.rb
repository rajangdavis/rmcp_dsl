# frozen_string_literal: true

# A rust_fn's `returns:` takes the helper types, so `:string?` declares a Rust function that returns
# Option<String> and a body must handle the nil (`|| default`, `.nil?`), as with a nil-able binding result
# (rmcp-for-blender gap #14: "no reply" no longer has to be a "" sentinel).
#
#   ruby -Ilib test/test_rust_fn_nilable.rb              # the emitted Rust
#   RMCP_CARGO=1 ruby -Ilib test/test_rust_fn_nilable.rb # also cargo-checks the crate (make test-ruby-rust)
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "rmcp_dsl"

class TestRustFnNilable < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)

  DSL = <<~'RB'
    server "s", version: "0.1.0" do
      rust_item <<~'RS'
        fn reply(s: &str) -> Option<String> { if s.is_empty() { None } else { Some(s.to_uppercase()) } }
        fn words(s: &str) -> Option<Vec<String>> { if s.is_empty() { None } else { Some(s.split(' ').map(String::from).collect()) } }
      RS
      rust_fn :reply, args: [:string], returns: :string?
      rust_fn :words, args: [:string], returns: :string_list?

      params :P do
        field :text, :string
      end

      tool :t, params: :P, description: "d" do
        body do |text|
          got = rust(:reply, text) || "no reply"
          n = (rust(:words, text) || []).length
          "#{got} #{n}"
        end
      end

      transport :stdio
    end
  RB

  def with_server(source = DSL)
    Dir.mktmpdir("rust-fn-nilable") do |dir|
      file = File.join(dir, "s.rmcp.rb")
      File.write(file, source)
      RmcpDsl::Notify.reset!
      yield file
    end
  end

  def test_a_nilable_result_is_accepted_through_a_fallback
    with_server do |file|
      ir = RmcpDsl.read(file)
      assert_equal "ostr", ir["externs"]["reply"]["returns"]
      assert_equal "ostrs", ir["externs"]["words"]["returns"]
      assert_includes RmcpDsl::Emit.files(ir, file)["src/main.rs"], "reply(&"
    end
  end

  def test_a_nilable_result_cannot_be_returned_unhandled
    source = DSL.sub('got = rust(:reply, text) || "no reply"', "got = rust(:reply, text)")
    with_server(source) do |file|
      err = assert_raises(RmcpDsl::CompileError) { RmcpDsl.read(file) }
      assert_match(/this value may be nil/, err.message)
    end
  end

  def test_a_plain_result_keeps_its_type
    source = DSL.sub("returns: :string?", "returns: :string").sub(' || "no reply"', "")
    with_server(source) do |file|
      assert_equal "string", RmcpDsl.read(file)["externs"]["reply"]["returns"]
    end
  end

  def test_the_emitted_crate_compiles
    skip "set RMCP_CARGO=1 to cargo-check the emitted crate (make test-ruby-rust)" unless ENV["RMCP_CARGO"]
    with_server do |file|
      out = File.join(File.dirname(file), "out")
      _o, err, status = Open3.capture3(RbConfig.ruby, EXE, "build", file, "-o", out)
      assert status.success?, err
      _o, err, status = Open3.capture3("cargo", "check", "-q", chdir: out)
      assert status.success?, "cargo check refused the emitted crate:\n#{err}"
    end
  end
end
