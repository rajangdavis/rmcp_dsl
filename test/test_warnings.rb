# frozen_string_literal: true

# L8 (started): a warning is printed where the source is, never fails the build, and is hidden
# by its environment variable without changing anything else. A typo in the gate is an error.
#
#   ruby -Ilib test/test_warnings.rb
require "minitest/autorun"
require "open3"
require "rbconfig"

class TestWarnings < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)
  DIR = File.expand_path("warnings", __dir__)

  def check(file, env = {})
    Open3.capture3(env, RbConfig.ruby, EXE, File.join(DIR, file), "--check")
  end

  def test_a_function_missing_from_its_module_warns_but_compiles
    _out, err, status = check("missing_fn.rb")
    assert status.success?, err
    assert_match(/missing_fn\.rb:\d+:\d+: warning W-RUST-FN-MISSING: `nope` is declared as living in module `m`/, err)
  end

  def test_a_function_that_is_there_does_not_warn
    _out, err, status = check("present_fn.rb")
    assert status.success?, err
    refute_includes err, "W-RUST-FN-MISSING"
  end

  def test_the_environment_gate_hides_a_warning_and_counts_it
    _out, err, status = check("missing_fn.rb", "RMCP_DSL_WARN" => "none")
    assert status.success?, err
    refute_includes err, "warning W-RUST-FN-MISSING"
    assert_includes err, "1 notification(s) hidden (W-RUST-FN-MISSING x1)"
  end

  def test_a_gate_can_name_the_codes_to_show
    _out, err, _status = check("missing_fn.rb", "RMCP_DSL_WARN" => "W-RUST-FN-MISSING")
    assert_includes err, "warning W-RUST-FN-MISSING"
  end

  def test_an_unknown_code_in_a_gate_is_an_error_not_a_silent_no_op
    _out, err, status = check("present_fn.rb", "RMCP_DSL_WARN" => "W-TYPO")
    refute status.success?
    assert_includes err, "RMCP_DSL_WARN: unknown code(s) W-TYPO"
  end
end
