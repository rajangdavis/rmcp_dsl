# frozen_string_literal: true

# use_dsl "dsl/x.rmcp.rb": a fragment's declarations spliced in at that line (docs/specs/use_dsl.md). A split
# server generates the same src/main.rs as the one-file server, and every error names the file that holds it.
#
#   ruby -Ilib test/test_use_dsl.rb
require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require "rmcp_dsl"

class TestUseDsl < Minitest::Test
  FIXTURES = File.expand_path("fixtures/use_dsl", __dir__)
  SPLIT = File.join(FIXTURES, "split", "splitkit.rmcp.rb")
  SINGLE = File.join(FIXTURES, "single", "splitkit.rmcp.rb")

  ROOT = <<~'RB'
    server "s", version: "0.1.0" do
      use_dsl "dsl/a.rmcp.rb"
      transport :stdio
    end
  RB

  TOOL = <<~'RB'
    fragment do
      params :P do
        field :name, :string
      end
      tool :t, params: :P, description: "d" do
        body { |name| name }
      end
    end
  RB

  # Writes `files` (relative path => text) into a temp folder and yields the root's path.
  def with_files(files)
    Dir.mktmpdir("use-dsl") do |dir|
      files.each do |rel, text|
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, text)
      end
      RmcpDsl::Notify.reset!
      yield File.join(dir, "s.rmcp.rb"), dir
    end
  end

  def refused(files, root = "s.rmcp.rb")
    with_files(files) do |_, dir|
      return assert_raises(RmcpDsl::CompileError) { RmcpDsl.read(File.join(dir, root)) }.message
    end
  end

  def test_a_split_server_generates_the_same_main_rs_as_the_one_file_server
    split = RmcpDsl.read(SPLIT)
    single = RmcpDsl.read(SINGLE)
    split_files = RmcpDsl::Emit.files(split, SPLIT)
    assert_equal RmcpDsl::Emit.files(single, SINGLE)["src/main.rs"], split_files["src/main.rs"]
    map = JSON.parse(split_files.fetch(RmcpDsl::CargoBuild::MAP))
    tool = map["ranges"].find { |r| r["what"] == "tool `greet`" }
    assert_equal File.join(FIXTURES, "split", "dsl", "tools.rmcp.rb"), tool["dsl_file"]
    assert_equal 5, tool["dsl_line"]
    params = map["ranges"].find { |r| r["what"] == "params `Greet`" }
    assert_equal [File.join(FIXTURES, "split", "dsl", "params.rmcp.rb"), 2], [params["dsl_file"], params["dsl_line"]]
  end

  def test_fragments_are_inputs_including_a_nested_one
    inputs = RmcpDsl.read(SPLIT)["inputs"]
    %w[helpers tools params].each do |name|
      assert_includes inputs, File.realpath(File.join(FIXTURES, "split", "dsl", "#{name}.rmcp.rb"))
    end
  end

  def test_a_rustc_error_in_a_fragment_tool_names_the_fragment
    map = { "source" => "s.rmcp.rb", "ranges" => [{ "from" => 1, "to" => 9, "dsl_line" => 5, "what" => "tool `t`", "dsl_file" => "dsl/a.rmcp.rb" }] }
    line = JSON.generate({ "reason" => "compiler-message",
                           "message" => { "level" => "error", "message" => "mismatched types", "rendered" => nil,
                                          "spans" => [{ "is_primary" => true, "file_name" => "src/main.rs", "line_start" => 3 }] } })
    io = StringIO.new
    RmcpDsl::CargoBuild.report(line, map, io)
    assert_match(%r{\Adsl/a\.rmcp\.rb:5: error: mismatched types}, io.string)
  end

  def test_an_error_in_a_fragment_names_the_fragment_and_its_line
    bad_body = TOOL.sub("body { |name| name }", "body { |name| nope(name) }")
    msg = refused("s.rmcp.rb" => ROOT, "dsl/a.rmcp.rb" => bad_body)
    assert_match(%r{/dsl/a\.rmcp\.rb:6:\d+: }, msg)
  end

  def test_a_declaration_late_checks_still_name_the_fragment
    unused = "fragment do\n  params :Unused do\n    field :x, :string\n  end\nend\n"
    root = ROOT.sub("  transport", "  use_dsl \"dsl/b.rmcp.rb\"\n  transport")
    msg = refused("s.rmcp.rb" => root, "dsl/a.rmcp.rb" => TOOL, "dsl/b.rmcp.rb" => unused)
    assert_match(%r{/dsl/b\.rmcp\.rb:2:\d+: params `Unused` is declared but no tool uses it}, msg)
  end

  def test_a_file_path_in_a_fragment_resolves_beside_the_fragment
    frag = TOOL.sub("fragment do\n", "fragment do\n  file \"data.txt\", as: :data\n").sub("body { |name| name }", "body { |name| \"\#{name}\#{file_text(:data)}\" }")
    with_files("s.rmcp.rb" => ROOT, "dsl/a.rmcp.rb" => frag, "dsl/data.txt" => "x") do |root, dir|
      ir = RmcpDsl.read(root)
      assert_equal File.realpath(File.join(dir, "dsl", "data.txt")), ir["files"][0]["real"]
    end
  end

  def test_refusals
    cases = {
      "use_dsl path must be relative" => { "s.rmcp.rb" => ROOT.sub("dsl/a.rmcp.rb", "../a.rmcp.rb") },
      "and end in .rmcp.rb" => { "s.rmcp.rb" => ROOT.sub("dsl/a.rmcp.rb", "dsl/a.rb") },
      "use_dsl file not found: dsl/a.rmcp.rb" => { "s.rmcp.rb" => ROOT },
      "is the file being built" => { "s.rmcp.rb" => ROOT.sub("dsl/a.rmcp.rb", "s.rmcp.rb") },
      "transport belongs in the file that says server" => { "s.rmcp.rb" => ROOT, "dsl/a.rmcp.rb" => TOOL.sub("fragment do\n", "fragment do\n  transport :stdio\n") },
      "expected exactly one top-level `fragment` call" => { "s.rmcp.rb" => ROOT, "dsl/a.rmcp.rb" => "#{TOOL}#{TOOL}" },
      "duplicate params `P`" => { "s.rmcp.rb" => ROOT.sub("  transport", "  params :P do\n    field :y, :string\n  end\n  transport"), "dsl/a.rmcp.rb" => TOOL }
    }
    cases.each { |expect, files| assert_includes refused(files), expect }
    twice = refused(cases.fetch("duplicate params `P`"))
    assert_match(%r{duplicate params `P` \(first at .*/dsl/a\.rmcp\.rb:2\)}, twice, "the first P is in the fragment")
    same_file = refused("s.rmcp.rb" => ROOT, "dsl/a.rmcp.rb" => TOOL.sub("  tool :t", "  params :P do\n    field :y, :string\n  end\n  tool :t"))
    refute_match(/first at/, same_file, "both in one file: the one-file wording")
    server_in_fragment = refused("s.rmcp.rb" => ROOT, "dsl/a.rmcp.rb" => "server \"x\", version: \"0.1.0\" do\nend\n")
    assert_includes server_in_fragment, "expected exactly one top-level `fragment` call"
  end

  def test_a_file_is_included_once
    twice = ROOT.sub("  transport", "  use_dsl \"dsl/a.rmcp.rb\"\n  transport")
    assert_match(%r{dsl/a\.rmcp\.rb is already included \(by .*/s\.rmcp\.rb:2\)}, refused("s.rmcp.rb" => twice, "dsl/a.rmcp.rb" => TOOL))
    cycle_a = TOOL.sub("fragment do\n", "fragment do\n  use_dsl \"b.rmcp.rb\"\n")
    cycle_b = "fragment do\n  use_dsl \"a.rmcp.rb\"\nend\n"
    assert_match(%r{dsl/a\.rmcp\.rb is already included \(by .*/s\.rmcp\.rb:2\)}, refused("s.rmcp.rb" => ROOT, "dsl/a.rmcp.rb" => cycle_a, "dsl/b.rmcp.rb" => cycle_b))
  end

  def test_building_a_fragment_says_which_file_to_build
    msg = refused({ "s.rmcp.rb" => ROOT, "dsl/a.rmcp.rb" => TOOL }, "dsl/a.rmcp.rb")
    assert_match(/a\.rmcp\.rb is a fragment; build the file that says use_dsl for it/, msg)
  end
end
