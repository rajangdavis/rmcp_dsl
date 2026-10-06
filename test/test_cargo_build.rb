# frozen_string_literal: true

require "minitest/autorun"
require "rmcp_dsl"
require "stringio"

# The map Emit writes must point at the lines it names, and CargoBuild must turn a rustc
# diagnostic inside a tool into the DSL line of that tool. Run from the repository root.
class TestCargoBuild < Minitest::Test
  def setup
    RmcpDsl::Notify.reset!
    @ir = RmcpDsl.read("examples/add.rmcp.rb")
    files = RmcpDsl::Emit.files(@ir, "examples/add.rmcp.rb")
    @main = files["src/main.rs"].lines
    @map = JSON.parse(files[RmcpDsl::CargoBuild::MAP])
  end

  def test_ranges_cover_each_declaration
    refute_empty @map["ranges"]
    @map["ranges"].each do |r|
      assert_operator r["from"], :<=, r["to"]
      assert_match(/\A\s*(#\[|struct )/, @main[r["from"] - 1], r["what"])
      assert_match(/\A\s*\}\s*\z/, @main[r["to"] - 1], r["what"])
    end
  end

  def test_every_tool_maps_to_its_dsl_line
    @ir["tools"].each do |t|
      r = @map["ranges"].find { |x| x["what"] == "tool `#{t['name']}`" }
      refute_nil r
      assert_equal t["line"], r["dsl_line"]
    end
  end

  def test_error_inside_a_tool_reports_the_dsl_line
    tool = @map["ranges"].find { |r| r["what"].start_with?("tool") }
    diag = { "reason" => "compiler-message",
             "message" => { "level" => "error", "message" => "mismatched types", "rendered" => "RENDERED\n",
                            "spans" => [{ "is_primary" => true, "file_name" => "src/main.rs", "line_start" => tool["from"] + 1 }] } }
    io = StringIO.new
    RmcpDsl::CargoBuild.report("#{JSON.generate(diag)}\n", @map, io)
    assert_includes io.string, "examples/add.rmcp.rb:#{tool['dsl_line']}: error: mismatched types"
    assert_includes io.string, "RENDERED"
  end

  def test_error_outside_any_declaration_keeps_rustcs_text
    diag = { "reason" => "compiler-message",
             "message" => { "level" => "error", "message" => "x", "rendered" => "RENDERED\n",
                            "spans" => [{ "is_primary" => true, "file_name" => "src/main.rs", "line_start" => 1 }] } }
    io = StringIO.new
    RmcpDsl::CargoBuild.report("#{JSON.generate(diag)}\n", @map, io)
    assert_equal "RENDERED\n", io.string
  end

  def test_other_cargo_messages_are_ignored
    io = StringIO.new
    RmcpDsl::CargoBuild.report("#{JSON.generate('reason' => 'build-finished', 'success' => true)}\n", @map, io)
    assert_equal "", io.string
  end
end
