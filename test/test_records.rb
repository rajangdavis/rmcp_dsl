# frozen_string_literal: true

# Records (docs/specs/typed_record.md): a binding type that lists its fields, `field :text, String` after type_rust.
# A body reads them, a list of them works like a list of params objects, an output may hold them, and the generated
# server checks the declaration against the Rust struct, at the binding's `field` line.
#
#   ruby -Ilib test/test_records.rb              # the reader's checks and the emitted Rust
#   RMCP_CARGO=1 ruby -Ilib test/test_records.rb # also builds the crate (make test-ruby-rust)
require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "rmcp_dsl"

class TestRecords < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)
  FIXTURE = File.expand_path("fixtures/records", __dir__)

  # A copy of the fixture, with `edits` ([relative path, from, to], ...) applied, so each case changes one thing.
  def with_rowkit(edits = [])
    Dir.mktmpdir("records") do |raw|
      dir = File.realpath(raw)
      FileUtils.cp_r(Dir.glob(File.join(FIXTURE, "*")), dir)
      edits.each do |rel, from, to|
        path = File.join(dir, rel)
        text = File.read(path)
        assert_includes text, from, "the edit for #{rel} matches nothing"
        File.write(path, text.sub(from, to))
      end
      RmcpDsl::Notify.reset!
      yield File.join(dir, "rowkit.rmcp.rb"), dir
    end
  end

  def refused(edits)
    with_rowkit(edits) { |file| return assert_raises(RmcpDsl::CompileError) { RmcpDsl.read(file) }.message }
  end

  def test_a_record_is_read_listed_returned_and_checked_against_its_rust_struct
    with_rowkit do |file, dir|
      ir = RmcpDsl.read(file)
      row = ir["opaque_types"].find { |t| t["name"] == "Rows::Row" }
      assert_equal [["text", "string", 11], ["href", "ostr", 12], ["rank", "i64", 13]], row["fields"]
      files = RmcpDsl::Emit.files(ir, file)
      main = files["src/main.rs"]
      assert_includes main, "fn check_record_rows_row(r: &rows::Row) {"
      assert_includes main, "    let _: rows::Row = r.clone();"
      assert_includes main, "    let _: &Option<String> = &r.href;"
      assert_includes main, "fn rows_make(count: i64) -> Vec<rows::Row> {"
      assert_includes main, "places: Vec<rows::Row>"
      assert_includes main, ".as_ref().and_then(|__o| __o.href.clone())"
      map = JSON.parse(files.fetch(RmcpDsl::CargoBuild::MAP))
      href = map["ranges"].find { |r| r["what"] == "field `href` of record Rows::Row" }
      assert_equal [File.join(dir, "bindings", "rows.rb"), 12], [href["dsl_file"], href["dsl_line"]]
    end
  end

  def test_a_plain_opaque_type_still_has_nothing_to_read
    fields = "    field :text, String\n    field :href, T.nilable(String)\n    field :rank, I64\n"
    msg = refused([["bindings/rows.rb", fields, ""], ["rowkit.rmcp.rb", 'rows.first&.href || "none"', '"none"']])
    assert_match(/Rows::Row is an opaque value with no methods of its own \(not `text`\)/, msg)
  end

  def test_reads_are_checked
    msg = refused([["rowkit.rmcp.rb", "r.text", "r.txt"]])
    assert_match(/Rows::Row has no field `txt` \(its fields: text, href, rank\); did you mean `text`/, msg)
    msg = refused([["rowkit.rmcp.rb", "rows.first&.href", "rows.first.href"]])
    assert_match(/may be nil, so read its fields with `&\.`/, msg)
  end

  def test_declarations_are_checked
    rows = "bindings/rows.rb"
    assert_match(/declares field `text` twice/, refused([[rows, "    field :rank, I64\n", "    field :rank, I64\n    field :text, String\n"]]))
    assert_match(/unsupported type `Integer`.*use I32 or I64/, refused([[rows, "field :rank, I64", "field :rank, Integer"]]))
    assert_match(/a record cannot hold another binding type/, refused([[rows, "field :rank, I64", "field :rank, Row"]]))
    assert_match(/field belongs inside `class Name < RmcpDsl::Opaque`/,
                 refused([[rows, "  sig { params(count: I64)", "  field :x, String\n\n  sig { params(count: I64)"]]))
    assert_match(/binding Rows has no type `Rw`.*did you mean `Row`/, refused([["rowkit.rmcp.rb", "list(Rows::Row)", "list(Rows::Rw)"]]))
    assert_match(/cannot be a field: its binding does not say `wire: true`/, refused([[rows, "wire: true", "wire: false"]]))
  end

  def test_the_editor_completes_and_finds_a_records_fields
    with_rowkit do |file, dir|
      typing = File.read(file).sub('link = rows.first&.href || "none"', "first = rows.first\n      link = first&.hr")
      a = RmcpDsl::Lsp::Analysis.new(file, typing)
      line0 = typing.lines.index { |l| l.include?("first&.hr") }
      col = typing.lines[line0].index("first&.hr") + "first&.hr".length
      assert_equal %w[href], RmcpDsl::Lsp::Completion.at(a, line0, col).map { |i| i["label"] }

      text = File.read(file)
      ok = RmcpDsl::Lsp::Analysis.new(file, text)
      binding = "file://#{File.join(dir, 'bindings', 'rows.rb')}"
      at = text.lines.index { |l| l.include?("r.text") }
      loc = RmcpDsl::Lsp::Definition.at(ok, at, text.lines[at].index("r.text") + 3, "file://#{file}")
      assert_equal [binding, 10], [loc["uri"], loc["range"]["start"]["line"]], "`field :text` is line 11"
      at = text.lines.index { |l| l.include?("list(Rows::Row)") }
      loc = RmcpDsl::Lsp::Definition.at(ok, at, text.lines[at].index("Row)") + 1, "file://#{file}")
      assert_equal [binding, 8], [loc["uri"], loc["range"]["start"]["line"]], "`class Row` is line 9"
    end
  end

  def test_hover_on_a_record_name_lists_its_fields
    with_rowkit do |file|
      text = File.read(file)
      a = RmcpDsl::Lsp::Analysis.new(file, text)
      at = text.lines.index { |l| l.include?("list(Rows::Row)") }
      hover = RmcpDsl::Lsp::Hover.at(a, at, text.lines[at].index("Rows::Row") + 2)
      value = hover.dig("contents", "value")
      assert_includes value, "**record** `Rows::Row` (Rust `rows::Row`, wire)"
      assert_includes value, "text: String\nhref: T.nilable(String)\nrank: Integer (i64)"
      assert_includes value, "declared in rows.rb:9"
    end
  end

  def test_rbi_gives_a_record_typed_readers
    with_rowkit do |file|
      rbi = RmcpDsl::Rbi.generate([file])
      assert_includes rbi, "class Rows::Row\n  sig { returns(String) }\n  def text; end\n"
      assert_includes rbi, "  sig { returns(T.nilable(String)) }\n  def href; end\n"
    end
  end

  def test_a_rust_struct_that_drifts_fails_at_the_field_line
    skip "set RMCP_CARGO=1 to build the emitted crate (make test-ruby-rust)" unless ENV["RMCP_CARGO"]
    with_rowkit do |file, dir|
      out = File.join(dir, "out")
      _o, err, status = Open3.capture3(RbConfig.ruby, EXE, "build", file, "-o", out)
      assert status.success?, err
    end
    with_rowkit([["rust/rows.rs", "pub href: Option<String>,", "pub link: Option<String>,"]]) do |file, dir|
      out = File.join(dir, "out")
      _o, err, status = Open3.capture3(RbConfig.ruby, EXE, "build", file, "-o", out)
      refute status.success?, "a struct without `href` should not build"
      assert_match(/#{Regexp.escape(File.join(dir, 'bindings', 'rows.rb'))}:12: error/, err)
    end
  end
end
