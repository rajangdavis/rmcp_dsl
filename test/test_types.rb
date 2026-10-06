# frozen_string_literal: true

# `check FILE --format json --types` also reports the inferred type of every parameter, local and
# expression. The positions are the contract the editor add-on codes against, so they are pinned here.
#
#   ruby -Ilib test/test_types.rb
require "minitest/autorun"
require "open3"
require "rbconfig"
require "json"
require "tmpdir"
require "rmcp_dsl"

class TestTypes < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)
  EXAMPLES = File.expand_path("../examples", __dir__)

  def run_check(name, *flags)
    out, err, status = Open3.capture3(RbConfig.ruby, EXE, "check", File.join(EXAMPLES, "#{name}.rmcp.rb"), "--format", "json", *flags)
    [JSON.parse(out, symbolize_names: true), err, status]
  end

  def types(name) = run_check(name, "--types").first.fetch(:types)

  # The source text an entry points at: lines and columns are 1-based, end_col is exclusive, columns count bytes.
  def source_of(name, entry)
    lines = File.binread(File.join(EXAMPLES, "#{name}.rmcp.rb")).lines
    first = lines[entry[:line] - 1]
    return first.byteslice(entry[:col] - 1, entry[:end_col] - entry[:col]) if entry[:line] == entry[:end_line]

    middle = lines[entry[:line]...(entry[:end_line] - 1)].join
    first.byteslice(entry[:col] - 1..) + middle + lines[entry[:end_line] - 1].byteslice(0, entry[:end_col] - 1)
  end

  def entry(line, col, end_line, end_col, kind, type, name = nil)
    { line: line, col: col, end_line: end_line, end_col: end_col, kind: kind, type: type }.tap { |e| e[:name] = name if name }
  end

  def test_without_the_flag_the_document_has_no_types
    doc, err, status = run_check("statkit")
    assert status.success?, err
    assert doc[:ok]
    refute doc.key?(:types)
  end

  def test_types_needs_check_with_json
    _out, _err, status = Open3.capture3(RbConfig.ruby, EXE, "check", File.join(EXAMPLES, "statkit.rmcp.rb"), "--types")
    refute status.success?
  end

  def test_an_error_has_no_types
    Dir.mktmpdir do |dir|
      bad = File.join(dir, "bad.rb")
      File.write(bad, "server(
")
      out, _err, status = Open3.capture3(RbConfig.ruby, EXE, "check", bad, "--format", "json", "--types")
      refute status.success?
      refute JSON.parse(out)["ok"]
      refute JSON.parse(out).key?("types")
    end
  end

  def test_the_compiled_ir_is_the_same_with_and_without_collecting
    path = File.join(EXAMPLES, "statkit.rmcp.rb")
    collector = RmcpDsl::TypeNames::Collector.new(path)
    assert_equal RmcpDsl.read(path), RmcpDsl.read(path, types: collector)
    refute_empty collector.entries
  end

  def test_entries_are_sorted_and_repeatable
    list = types("statkit")
    keys = list.map { |e| [e[:line], e[:col], -e[:end_line]] }
    assert_equal keys.sort, keys
    assert_equal list, types("statkit")
  end

  def test_every_entry_points_at_the_source_it_describes
    %w[statkit webkit formkit].each do |name|
      types(name).each do |e|
        text = source_of(name, e)
        refute_empty text, "#{name}: #{e}"
        case e[:kind]
        when "parameter", "local" then assert_equal e[:name], text, "#{name}: #{e}"
        when "field" then assert_match(/\Afield :#{e[:name]},/, text, "#{name}: #{e}")
        when "helper" then assert_match(/\Ahelper :#{e[:name]},.*\bend\z/m, text, "#{name}: #{e}")
        when "output" then assert_match(/\A(output :|result\(:)#{e[:name]}\b/, text, "#{name}: #{e}")
        end
      end
    end
  end

  def test_a_helper_declaration_and_a_call_of_it
    list = types("webkit")
    assert_includes list, entry(27, 3, 33, 6, "helper", "(String) -> String", "checked_host")
    assert_includes list, entry(27, 63, 27, 66, "parameter", "String", "url")
    assert_includes list, entry(36, 3, 42, 6, "helper", "(String) -> T::Array[String]", "checked_addresses")
    assert_includes list, entry(46, 3, 49, 6, "helper", "(String, Integer (i64), T::Array[String]) -> String", "pin_arg")
    call = entry(37, 12, 37, 29, "expression", "String")
    assert_includes list, call
    assert_equal "checked_host(url)", source_of("webkit", call)
  end

  def test_a_nil_able_first
    list = types("statkit")
    first = entry(27, 64, 27, 75, "expression", "T.nilable(String)")
    assert_includes list, first
    assert_equal "items.first", source_of("statkit", first)
  end

  def test_an_optional_field
    list = types("statkit")
    assert_includes list, entry(18, 5, 18, 73, "field", "T.nilable(String)", "first")
    assert_includes list, entry(17, 5, 17, 70, "field", "T::Array[String]", "items")
    assert_includes list, entry(16, 5, 16, 57, "field", "Counts", "counts")
    assert_includes list, entry(19, 5, 19, 79, "field", "T::Boolean", "shout")
    assert_includes list, entry(10, 5, 10, 54, "field", "Integer (i64)", "items")
  end

  def test_an_output_declaration_and_a_nested_result
    list = types("statkit")
    assert_includes list, entry(9, 3, 12, 6, "output", "Counts", "Counts")
    assert_includes list, entry(14, 3, 20, 6, "output", "Stats", "Stats")
    outer = entry(26, 7, 27, 104, "output", "Stats", "Stats")
    inner = entry(26, 42, 26, 105, "output", "Counts", "Counts")
    assert_includes list, outer
    assert_includes list, inner
    assert_match(/\Aresult\(:Counts, items: items\.length, unique: items\.uniq\.length\)\z/, source_of("statkit", inner))
    assert_operator list.index(outer), :<, list.index(inner)
  end

  def test_a_local_at_its_declaration_and_at_a_read
    list = types("statkit")
    assert_includes list, entry(24, 7, 24, 12, "local", "T::Array[String]", "items")
    assert_includes list, entry(25, 27, 25, 32, "local", "T::Array[String]", "items")
    assert_includes list, entry(23, 14, 23, 18, "parameter", "String", "text")
    assert_includes list, entry(24, 15, 24, 19, "parameter", "String", "text")
    assert_includes list, entry(27, 42, 27, 43, "parameter", "String", "i") # a list block's parameter
    assert_includes list, entry(25, 7, 25, 23, "expression", "T.noreturn")
  end

  def test_an_interpolation
    list = types("webkit")
    line = File.readlines(File.join(EXAMPLES, "webkit.rmcp.rb"))[47]
    col = line.index('"#{host}:#{port}:[#{addr}]"') + 1
    found = list.select { |e| e[:line] == 48 && e[:col] == col && e[:kind] == "expression" }
    assert_equal ["String"], found.map { |e| e[:type] }
    assert_equal '"#{host}:#{port}:[#{addr}]"', source_of("webkit", found.first)
    assert_includes list, entry(48, col + 3, 48, col + 7, "parameter", "String", "host")
  end

  def test_type_names
    names = RmcpDsl::TypeNames
    shown = { string: "String", str: "String", i32: "Integer (i32)", i64: "Integer (i64)", f64: "Float", bool: "T::Boolean",
              strs: "T::Array[String]", i64s: "T::Array[Integer (i64)]", ostr: "T.nilable(String)", oi32: "T.nilable(Integer (i32))",
              oi64: "T.nilable(Integer (i64))", of64: "T.nilable(Float)", obool: "T.nilable(T::Boolean)",
              ostrs: "T.nilable(T::Array[String])", oi64s: "T.nilable(T::Array[Integer (i64)])", regex: "Regexp",
              never: "T.noreturn", int: "Integer", "struct:Counts": "Counts" }
    shown.each { |sym, text| assert_equal text, names.display(sym), sym.inspect }
  end
end
