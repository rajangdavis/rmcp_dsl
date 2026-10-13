# frozen_string_literal: true

# PythonSig reads `def` headers and TypedDict bodies from Python text without running Python, refusing what it
# cannot read (docs/specs/source_hook.md).
#
#   ruby -Ilib test/test_python_sig.rb
require "minitest/autorun"
require "rmcp_dsl"

class TestPythonSig < Minitest::Test
  SIG = RmcpDsl::PythonSig

  SOURCE = <<~'PY'
    from typing import NotRequired, Optional, TypedDict


    class PlaceArgs(TypedDict):
        """Where to put an object."""
        name: str
        x: float | None
        tags: list[str]
        scale: NotRequired[float]  # absent means unchanged
        rx: Optional[float]


    def place(args: PlaceArgs) -> dict:
        return {}


    def scale(
        name: str,
        factor: float = 1.0,
    ) -> str:
        return name


    def bare(args) -> str:
        return ""


    def splat(*args: str) -> str:
        return ""
  PY

  def test_a_one_line_header_is_read
    d = SIG.signature(SOURCE, "place")
    assert_equal 13, d.line
    assert_equal ["args"], d.params.map(&:name)
    assert_equal "PlaceArgs", d.params[0].annotation
    assert_equal "dict", d.returns
  end

  def test_a_header_over_several_lines_is_read_with_its_defaults
    d = SIG.signature(SOURCE, "scale")
    assert_equal 17, d.line
    assert_equal %w[name factor], d.params.map(&:name)
    assert_equal %w[str float], d.params.map(&:annotation)
    assert_nil d.params[0].default
    assert_equal "1.0", d.params[1].default
    assert_equal "str", d.returns
  end

  def test_a_missing_def_is_nil_and_an_unannotated_parameter_is_reported_as_such
    assert_nil SIG.signature(SOURCE, "gone")
    assert_nil SIG.signature(SOURCE, "bare").params[0].annotation
  end

  def test_star_parameters_are_refused
    err = assert_raises(SIG::Unreadable) { SIG.signature(SOURCE, "splat") }
    assert_match(/uses `\*args: str`/, err.message)
  end

  def test_typed_dict_fields_carry_type_requiredness_and_line
    fields = SIG.typed_dict(SOURCE, "PlaceArgs")
    assert_equal %w[name x tags scale rx], fields.map(&:name)
    by = fields.to_h { |f| [f.name, f] }
    assert_equal [:string, false, true, 6], [by["name"].type.base, by["name"].type.nilable, by["name"].required, by["name"].line]
    assert_equal [:f64, true], [by["x"].type.base, by["x"].type.nilable]
    assert_equal :strs, by["tags"].type.base
    assert_equal [:f64, false, false], [by["scale"].type.base, by["scale"].type.nilable, by["scale"].required]
    assert_equal [:f64, true], [by["rx"].type.base, by["rx"].type.nilable]
    assert_nil SIG.typed_dict(SOURCE, "Nope")
  end

  def test_annotations_outside_the_checkable_subset_are_refused
    err = assert_raises(SIG::Unreadable) { SIG.parse_type("dict[str, Any]", "A.meta") }
    assert_match(/A.meta: `dict\[str, Any\]` cannot be checked/, err.message)
    assert_raises(SIG::Unreadable) { SIG.parse_type("int | str", "A.n") }
  end

  def test_a_literal_of_strings_is_a_string_with_its_values
    t = SIG.parse_type(%(Literal["mp4", 'webm'] | None), "A.format")
    assert_equal [:string, true, %w[mp4 webm]], [t.base, t.nilable, t.literals]
    assert_nil SIG.parse_type("str", "A.name").literals
    err = assert_raises(SIG::Unreadable) { SIG.parse_type("Literal[1, 2]", "A.n") }
    assert_match(/A.n: `Literal\[1, 2\]` cannot be checked; a Literal must list plain strings/, err.message)
  end

  def test_a_name_defined_twice_at_the_top_level_is_refused
    twice = "def f(a: int) -> int:\n    return a\n\n\ndef f(a: str) -> str:\n    return a\n"
    err = assert_raises(SIG::Unreadable) { SIG.signature(twice, "f") }
    assert_match(/`def f` is defined 2 times at the top level \(lines 1, 5\); Python keeps the last/, err.message)
    classes = "class A(TypedDict):\n    x: int\n\n\nclass A(TypedDict):\n    y: str\n"
    err = assert_raises(SIG::Unreadable) { SIG.typed_dict(classes, "A") }
    assert_match(/`class A` is defined 2 times at the top level \(lines 1, 5\)/, err.message)
  end

  def test_a_typed_dict_with_total_false_is_refused
    err = assert_raises(SIG::Unreadable) { SIG.typed_dict("class A(TypedDict, total=False):\n    x: int\n", "A") }
    assert_match(/total=False/, err.message)
  end
end
