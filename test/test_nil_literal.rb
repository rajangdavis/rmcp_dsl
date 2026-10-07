# frozen_string_literal: true

# `nil` is a value: it makes a conditional arm nil-able (`cond ? x : nil`), which emits `Some`/`None`,
# and it fits an optional output field. A nil where a non-nilable value is wanted is a type error.
#
#   ruby -Ilib test/test_nil_literal.rb
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "rmcp_dsl"

class TestNilLiteral < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)

  SRC = <<~RB
    server "s", version: "0.1.0" do
      params :P do
        field :n, :i64
      end

      output :Out do
        field :next, :i64, optional: true
      end

      tool :t, params: :P, description: "d", output: :Out do
        body do |n|
          nxt = n < 10 ? n + 1 : nil
          result(:Out, next: nxt)
        end
      end

      transport :stdio
    end
  RB

  def test_a_nil_arm_emits_some_and_none
    Dir.mktmpdir do |dir|
      file = File.join(dir, "s.rmcp.rb")
      File.write(file, SRC)
      _out, err, status = Open3.capture3(RbConfig.ruby, EXE, "check", file)
      assert status.success?, err
      main = RmcpDsl::Emit.files(RmcpDsl.read(file), file)["src/main.rs"]
      assert_includes main, "else { None }"
      assert_includes main, "Some("
    end
  end
end
