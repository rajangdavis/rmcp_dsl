# frozen_string_literal: true

# Field descriptions reach the JSON schema, and `raise` (or checked arithmetic) turns a tool into
# one that returns an MCP error result. Servers that cannot fail keep their plain String return.
#
#   ruby -Ilib test/test_errors_and_fields.rb
require "minitest/autorun"
require "rmcp_dsl"
require "tmpdir"

class TestErrorsAndFields < Minitest::Test
  def main_rs(source)
    Dir.mktmpdir("emit") do |dir|
      file = File.join(dir, "s.rb")
      File.write(file, source)
      RmcpDsl::Notify.reset!
      RmcpDsl::Emit.files(RmcpDsl.read(file), file).fetch("src/main.rs")
    end
  end

  RAISING = <<~'RB'
    server "demo", version: "0.1.0" do
      params :P do
        field :text, :string, description: "The \"text\" to check"
        field :other, :string
      end

      tool :check, params: :P, description: "d" do
        body do |text|
          text.empty? ? raise("empty text") : text
        end
      end

      tool :echo, params: :P, description: "d" do
        body do |other|
          other.start_with?("!") ? raise(other) : other
        end
      end

      transport :stdio
    end
  RB

  PLAIN = <<~'RB'
    server "plain", version: "0.1.0" do
      params :P do
        field :text, :string
      end

      tool :up, params: :P, description: "d" do
        body do |text|
          text.upcase
        end
      end

      transport :stdio
    end
  RB

  def test_field_description_becomes_a_schemars_attribute
    rs = main_rs(RAISING)
    assert_includes rs, '#[schemars(description = "The \"text\" to check")]'
    assert_equal 1, rs.scan("#[schemars(").size, "only the described field gets one"
  end

  def test_raise_makes_the_tool_return_an_error_result
    rs = main_rs(RAISING)
    assert_includes rs, "use rmcp::model::{CallToolResult, ContentBlock};"
    assert_includes rs, "-> Result<CallToolResult, rmcp::ErrorData>"
    assert_includes rs, 'return Err("empty text".to_string())'
    assert_includes rs, "return Err(other)", "a string expression is raised as is"
    assert_includes rs, "Err(e) => CallToolResult::error(vec![ContentBlock::text(e)])"
  end

  # rustc warns about `{ (if ...) }`; generated code must stay warning-free (SPEC.md, DESIGN.md).
  def test_parenthesized_arms_get_no_redundant_parentheses
    rs = main_rs(<<~'RB')
      server "parens", version: "0.1.0" do
        params :P do
          field :text, :string
        end

        tool :t, params: :P, description: "d" do
          body do |text|
            text.empty? ? "none" : (text.start_with?("(") ? "open" : text)
          end
        end

        transport :stdio
      end
    RB
    refute_includes rs, "else { (if", "the parentheses around the inner if are redundant"
    assert_includes rs, "else { if text.starts_with"
    assert_includes rs, "(\"(\")", "a parenthesis inside a string literal is left alone"
  end

  def test_a_server_that_cannot_fail_is_unchanged
    rs = main_rs(PLAIN)
    refute_includes rs, "CallToolResult"
    refute_includes rs, "schemars("
    assert_includes rs, "-> String {"
  end

  def test_checked_arithmetic_also_returns_error_results
    rs = main_rs(<<~'RB')
      server "calc", version: "0.1.0" do
        params :P do
          field :a, :i32
          field :b, :i32
        end

        tool :add, params: :P, description: "d" do
          body do |a, b|
            (a + b).to_s
          end
        end

        transport :stdio
      end
    RB
    assert_includes rs, "-> Result<CallToolResult, rmcp::ErrorData>"
    assert_includes rs, "CallToolResult::error"
  end
end
