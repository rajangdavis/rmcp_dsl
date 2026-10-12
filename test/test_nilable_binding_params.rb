# frozen_string_literal: true

# A binding parameter can be T.nilable(...): the callee decides what nil means, instead of every caller folding
# nil itself (rmcp-for-blender gap #15). The wrapper takes an owned Option, so a call passes nil as None, a plain
# value as Some(...), and a nil-able value as it is; a local is cloned so the body can read it again.
#
#   ruby -Ilib test/test_nilable_binding_params.rb              # the emitted Rust
#   RMCP_CARGO=1 ruby -Ilib test/test_nilable_binding_params.rb # also cargo-checks the crate (make test-ruby-rust)
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "rmcp_dsl"

class TestNilableBindingParams < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)

  BINDING = <<~'RB'
    # typed: true
    module Tally
      extend T::Sig
      extend RmcpDsl::BindingDsl

      sig { params(xs: T.nilable(T::Array[String])).returns(String) }
      def self.count(xs)
        (xs || []).length.to_s
      end
      example :count, nil, expect: "0"
      example :count, ["a", "b"], expect: "2"
    end
  RB

  DSL = <<~'RB'
    server "s", version: "0.1.0" do
      use_bindings :tally

      params :P do
        field :names, :string_list
        field :maybe, :string_list, optional: true
      end

      tool :t, params: :P, description: "d" do
        body do |names, maybe|
          "#{Tally.count(nil)} #{Tally.count(names)} #{Tally.count(maybe)} #{names.length}"
        end
      end

      transport :stdio
    end
  RB

  def with_server(binding = BINDING)
    Dir.mktmpdir("nilable-params") do |dir|
      FileUtils.mkdir_p(File.join(dir, "bindings"))
      File.write(File.join(dir, "bindings", "tally.rb"), binding)
      file = File.join(dir, "s.rmcp.rb")
      File.write(file, DSL)
      RmcpDsl::Notify.reset!
      yield file
    end
  end

  def test_nil_a_value_and_a_nilable_value_are_all_accepted
    with_server do |file|
      _out, err, status = Open3.capture3(RbConfig.ruby, EXE, "check", file)
      assert status.success?, err
      main = RmcpDsl::Emit.files(RmcpDsl.read(file), file)["src/main.rs"]
      assert_includes main, "xs: Option<Vec<String>>"
      assert_includes main, "(None)"
      assert_includes main, "(Some(names.clone()))"
      assert_includes main, "(maybe.clone())"
    end
  end

  def test_a_wrong_inner_type_is_refused
    bad = BINDING.sub("T.nilable(T::Array[String])", "T.nilable(I64)").sub("(xs || []).length.to_s", "(xs || 0).to_s")
                 .sub('example :count, ["a", "b"], expect: "2"', "")
    with_server(bad) do |file|
      err = assert_raises(RmcpDsl::CompileError) { RmcpDsl.read(file) }
      assert_match(/argument `xs` should be/, err.message)
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
