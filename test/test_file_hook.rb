# frozen_string_literal: true

# `file "x.py", as: :x, entries: [...]`: a file the server reads from disk on each call, its Python entries and
# their arguments checked at build (docs/specs/source_hook.md).
#
#   ruby -Ilib test/test_file_hook.rb              # the reader's checks and the emitted Rust
#   RMCP_CARGO=1 ruby -Ilib test/test_file_hook.rb # also cargo-checks the crate (make test-ruby-rust)
require "minitest/autorun"
require "json"
require "open3"
require "timeout"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "rmcp_dsl"

class TestFileHook < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)

  PY = <<~'PY'
    from typing import NotRequired, TypedDict


    class PlaceArgs(TypedDict):
        name: str
        x: float | None
        scale: NotRequired[float]


    def place(args: PlaceArgs) -> dict:
        return {"report": args["name"]}


    def shout(text: str, times: int = 1) -> str:
        return text.upper() * times
  PY

  DSL = <<~'RB'
    server "s", version: "0.1.0" do
      file "py/scripts.py", as: :scripts, env: "S_SCRIPTS", entries: %i[place shout]

      params :P do
        field :name, :string
        field :x, :f64, optional: true
      end

      tool :t, params: :P, description: "d" do
        body do |name, x|
          source = file_text(:scripts)
          a = entry_args(:scripts, :place, name: name, x: x)
          b = entry_args(:scripts, :shout, text: name)
          "#{source.length} #{entry(:scripts, :place)} #{entry(:scripts, :shout)} #{a} #{b}"
        end
      end

      transport :stdio
    end
  RB

  def with_server(dsl = DSL, py = PY)
    Dir.mktmpdir("file-hook") do |dir|
      FileUtils.mkdir_p(File.join(dir, "py"))
      File.write(File.join(dir, "py", "scripts.py"), py)
      file = File.join(dir, "s.rmcp.rb")
      File.write(file, dsl)
      RmcpDsl::Notify.reset!
      yield file
    end
  end

  def refused(dsl, py = PY)
    with_server(dsl, py) { |file| return assert_raises(RmcpDsl::CompileError) { RmcpDsl.read(file) }.message }
  end

  def check_output(dsl)
    with_server(dsl) do |file|
      out, err, status = Open3.capture3(RbConfig.ruby, EXE, "check", file)
      assert status.success?, err
      return out + err
    end
  end

  def test_a_good_declaration_reads_the_file_and_builds_checked_arguments
    with_server do |file|
      ir = RmcpDsl.read(file)
      f = ir["files"].fetch(0)
      assert_equal %w[place shout], f["entries"]
      assert f["text_read"]
      assert_equal "dict", f["sigs"]["place"]["shape"]
      assert_equal "params", f["sigs"]["shout"]["shape"]
      main = RmcpDsl::Emit.files(ir, file)["src/main.rs"]
      assert_includes main, "fn file_text_scripts() -> Result<String, String>"
      assert_includes main, "std::env::var(\"S_SCRIPTS\")"
      assert_includes main, "rmcp::serde_json::json!({\"name\": ("
      assert_includes main, "\"x\": ("
    end
    refute_match(/W-FILE-ARGS-UNCHECKED/, check_output(DSL))
  end

  def test_an_entry_missing_from_the_file_is_refused
    msg = refused(DSL.sub("%i[place shout]", "%i[place shout gone]"))
    assert_match(%r{`gone` is listed in entries: but py/scripts.py has no top-level `def gone\(`}, msg)
  end

  def test_an_unannotated_entry_is_refused
    msg = refused(DSL, PY.sub("def shout(text: str,", "def shout(text,"))
    assert_match(/needs a type on each parameter and a return type/, msg)
  end

  def test_an_unknown_key_is_refused_with_a_suggestion
    msg = refused(DSL.sub("name: name, x: x", "nam: name, x: x"))
    assert_match(/`nam` is not a field of PlaceArgs \(name, x, scale\); did you mean `name`/, msg)
  end

  def test_a_missing_required_key_is_refused_with_its_line
    msg = refused(DSL.sub("name: name, x: x", "x: x"))
    assert_match(%r{PlaceArgs requires `name` \(py/scripts.py:5\)}, msg)
  end

  def test_a_wrong_type_is_refused
    msg = refused(DSL.sub("name: name, x: x", "name: name, x: name"))
    assert_match(/`x` is `x: float \| None` in PlaceArgs, got/, msg)
  end

  def test_a_nilable_value_into_a_field_without_none_is_refused
    msg = refused(DSL.sub("name: name, x: x", "name: x, x: x"))
    assert_match(/`name` may be nil here, but PlaceArgs declares `name: str`/, msg)
  end

  def test_an_uncheckable_annotation_is_refused_unless_args_is_unchecked
    py = PY.sub("scale: NotRequired[float]", "meta: dict[str, int]")
    assert_match(/PlaceArgs.meta: `dict\[str, int\]` cannot be checked/, refused(DSL, py))
    with_server(DSL.sub("entries: %i[place shout]", "entries: %i[place shout], unchecked: %i[args]"), py) do |file|
      RmcpDsl.read(file)
    end
  end

  def test_unknown_files_and_entries_are_refused_with_suggestions
    assert_match(/no file has as: :script .*did you mean `scripts`/, refused(DSL.sub("file_text(:scripts)", "file_text(:script)")))
    assert_match(/not in the entries of :scripts .*did you mean `shout`/, refused(DSL.sub("entry(:scripts, :shout)", "entry(:scripts, :shot)")))
  end

  def test_unused_files_and_entries_are_refused
    two = DSL.sub("entries: %i[place shout]\n", "entries: %i[place shout]\n  file \"py/scripts.py\", as: :other\n")
    assert_match(/file `other` is declared but nothing reads it/, refused(two))
    unnamed = DSL.sub(' #{entry(:scripts, :shout)}', "").sub("b = entry_args(:scripts, :shout, text: name)\n", "").sub(" \#{b}", "")
    assert_match(/entry `shout` of file `scripts` is listed but nothing names it/, refused(unnamed))
  end

  def test_bad_declarations_are_refused
    assert_match(/`:bogus` is not one of :each_read :args/, refused(DSL.sub("%i[place shout]", "%i[place shout], unchecked: %i[bogus]")))
    assert_match(/file path must be relative/, refused(DSL.sub('"py/scripts.py"', '"../scripts.py"')))
    assert_match(/duplicate file `scripts`/, refused(DSL.sub("entries: %i[place shout]\n", "entries: %i[place shout]\n  file \"py/scripts.py\", as: :scripts\n")))
  end

  def test_unchecked_and_unbuilt_arguments_are_reported
    assert_match(/N-FILE-UNCHECKED/, check_output(DSL.sub("%i[place shout]", "%i[place shout], unchecked: %i[each_read]")))
    named_only = DSL.sub("b = entry_args(:scripts, :shout, text: name)", 'b = "{}"')
    assert_match(/W-FILE-ARGS-UNCHECKED.*entry_args\(:scripts, :shout/, check_output(named_only))
  end

  LIT_PY = <<~'PY'
    from typing import Literal, TypedDict


    class ExportArgs(TypedDict):
        format: Literal["glb", "fbx"]


    def export(args: ExportArgs) -> dict:
        return {}
  PY

  LIT_DSL = <<~'RB'
    server "s", version: "0.1.0" do
      file "py/scripts.py", as: :scripts, entries: %i[export]

      params :P do
        field :format, :string, enum: ["glb", "fbx"], default: "glb"
        field :other, :string
      end

      tool :t, params: :P, description: "d" do
        body do |format, other|
          a = entry_args(:scripts, :export, format: format)
          b = entry_args(:scripts, :export, format: "fbx")
          "#{other} #{a} #{b} #{file_path(:scripts)}"
        end
      end

      transport :stdio
    end
  RB

  def test_a_literal_field_takes_a_listed_string_or_an_enum_parameter_within_it
    with_server(LIT_DSL, LIT_PY) do |file|
      main = RmcpDsl::Emit.files(RmcpDsl.read(file), file)["src/main.rs"]
      assert_includes main, "file_path_scripts().display().to_string()"
    end
    msg = refused(LIT_DSL.sub('format: "fbx")', 'format: "obj")'), LIT_PY)
    assert_match(/"obj" is not one of `format: Literal\["glb", "fbx"\]` in ExportArgs/, msg)
    msg = refused(LIT_DSL.sub('enum: ["glb", "fbx"]', 'enum: ["glb", "fbx", "obj"]'), LIT_PY)
    assert_match(/`format` allows "obj" \(its enum:\), which `format: Literal\["glb", "fbx"\]` in ExportArgs does not/, msg)
    msg = refused(LIT_DSL.sub("format: format)", "format: other)"), LIT_PY)
    assert_match(/pass one of "glb", "fbx", or a parameter declared with enum:/, msg)
  end

  def test_the_emitted_crate_compiles
    skip "set RMCP_CARGO=1 to cargo-check the emitted crate (make test-ruby-rust)" unless ENV["RMCP_CARGO"]
    with_server do |file|
      out = File.join(File.dirname(file), "out")
      _o, err, status = Open3.capture3(RbConfig.ruby, EXE, "build", file, "-o", out)
      assert status.success?, err
      _o, err, status = Open3.capture3("cargo", "check", "-q", chdir: out)
      assert status.success?, "cargo check refused the emitted crate:\n#{err}"

      # The server checks the file before it serves: an entry gone, or a TypedDict field changed since the build,
      # stops it with exit 2 and a message naming what changed (the same check a read repeats while it runs).
      dir = File.dirname(file)
      gone = File.join(dir, "gone.py")
      File.write(gone, PY.sub(/^def shout.*\z/m, ""))
      _o, err, status = Open3.capture3({ "S_SCRIPTS" => gone }, "cargo", "run", "-q", chdir: out, stdin_data: "")
      assert_equal 2, status.exitstatus, err
      assert_match(/has no top-level `def shout\(` any more/, err)

      retyped = File.join(dir, "retyped.py")
      File.write(retyped, PY.sub("x: float | None", "x: str"))
      _o, err, status = Open3.capture3({ "S_SCRIPTS" => retyped }, "cargo", "run", "-q", chdir: out, stdin_data: "")
      assert_equal 2, status.exitstatus, err
      assert_match(/field `x` of PlaceArgs changed \(was `x: float \| None`, now `x: str`\)/, err)

      # A later def of the same name is the one Python calls, so it is the one compared.
      shadowed = File.join(dir, "shadowed.py")
      File.write(shadowed, "#{PY}\n\ndef place(args: PlaceArgs, extra: int) -> dict:\n    return {}\n")
      _o, err, status = Open3.capture3({ "S_SCRIPTS" => shadowed }, "cargo", "run", "-q", chdir: out, stdin_data: "")
      assert_equal 2, status.exitstatus, err
      assert_match(/`def place` in .* changed since the server was built/, err)

      # While it runs, each read re-checks: an entry removed after startup fails the next call by name.
      live = File.join(dir, "live.py")
      File.write(live, PY)
      stdin, stdout, _stderr, wait = Open3.popen3({ "S_SCRIPTS" => live }, "cargo", "run", "-q", chdir: out)
      begin
        io = [stdin, stdout]
        rpc(io, 1, "initialize", { "protocolVersion" => "2025-06-18", "capabilities" => {}, "clientInfo" => { "name" => "t", "version" => "0" } })
        stdin.puts(JSON.generate({ "jsonrpc" => "2.0", "method" => "notifications/initialized" }))
        stdin.flush
        ok = rpc(io, 2, "tools/call", { "name" => "t", "arguments" => { "name" => "a" } })
        refute ok.dig("result", "isError"), ok.to_json
        File.write(live, PY.sub(/^def shout.*\z/m, ""))
        gone = rpc(io, 3, "tools/call", { "name" => "t", "arguments" => { "name" => "a" } })
        assert_match(/has no top-level `def shout\(` any more/, gone.to_json)
      ensure
        stdin.close
        wait.value
      end
    end
  end

  # One JSON-RPC request to a server on stdio; notifications on the way are skipped.
  def rpc(io, id, method, params)
    stdin, stdout = io
    stdin.puts(JSON.generate({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params }))
    stdin.flush
    Timeout.timeout(180) do
      loop do
        line = stdout.gets or raise "the server closed its output"
        reply = JSON.parse(line)
        return reply if reply["id"] == id
      end
    end
  end

  def test_go_to_definition_on_an_entry_opens_its_def_line
    with_server do |file|
      analysis = RmcpDsl::Lsp::Analysis.new(file, DSL)
      line0 = DSL.lines.index { |l| l.include?("entry(:scripts, :place)") }
      col = DSL.lines[line0].index("entry(:scripts, :place)") + "entry(:scripts, :".length + 1
      loc = RmcpDsl::Lsp::Definition.at(analysis, line0, col, "file://#{file}")
      assert loc, "no definition for the entry"
      assert loc["uri"].end_with?("/py/scripts.py"), loc["uri"]
      assert_equal 9, loc["range"]["start"]["line"] # `def place` is line 10 of PY
    end
  end

  def test_completion_offers_the_entries_while_the_call_is_typed
    typing = DSL.sub("      source = file_text(:scripts)\n", "      source = file_text(:scripts)\n      partial = entry(:scripts, :\n")
    refute_equal DSL, typing, "the half-typed line was not inserted"
    with_server(typing) do |file|
      analysis = RmcpDsl::Lsp::Analysis.new(file, typing)
      refute analysis.ok?, "the half-typed call should not compile"
      line0 = typing.lines.index { |l| l.include?("partial = entry(:scripts, :") }
      col = typing.lines[line0].chomp.length
      labels = RmcpDsl::Lsp::Completion.at(analysis, line0, col).map { |i| i["label"] }
      assert_equal %w[place shout], labels.sort
    end
  end

  def test_the_server_is_built_to_recheck_entries_on_each_read_unless_turned_off
    with_server do |file|
      main = RmcpDsl::Emit.files(RmcpDsl.read(file), file)["src/main.rs"]
      assert_includes main, "check_file_entries(\"scripts\", &path, &text, FILE_ENTRIES_SCRIPTS)?;\n    Ok(text)"
      assert_includes main, "if let Err(message) = check_files()"
      assert_includes main, "header: \"def place(args: PlaceArgs) -> dict:\", dict: \"PlaceArgs\""
      assert_includes main, "(\"x\", \"x: float | None\")"
    end
    with_server(DSL.sub("%i[place shout]", "%i[place shout], unchecked: %i[each_read]")) do |file|
      main = RmcpDsl::Emit.files(RmcpDsl.read(file), file)["src/main.rs"]
      refute_includes main, "&text, FILE_ENTRIES_SCRIPTS)?;\n    Ok(text)"
      assert_includes main, "if let Err(message) = check_files()"
    end
  end
end
