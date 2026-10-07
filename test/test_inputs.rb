# frozen_string_literal: true

# The compiler names the files it read — the DSL file, every use_bindings file, each rust_file and
# each openapi document — so a watcher can be built from that list instead of a hand-kept one.
#
#   ruby -Ilib test/test_inputs.rb
require "minitest/autorun"
require "open3"
require "rbconfig"
require "json"

class TestInputs < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)
  EXAMPLES = File.expand_path("../examples", __dir__)

  def inputs(name)
    out, err, status = Open3.capture3(RbConfig.ruby, EXE, "check", File.join(EXAMPLES, name), "--print-inputs")
    assert status.success?, "check #{name} --print-inputs failed:\n#{err}"
    out.lines.map(&:chomp)
  end

  def test_bindings_are_inputs
    list = inputs("bindings.rmcp.rb")
    assert_includes list, File.join(EXAMPLES, "bindings.rmcp.rb")
    assert_includes list, File.join(EXAMPLES, "bindings", "heck.rb")
    assert_includes list, File.join(EXAMPLES, "bindings", "words.rb")
  end

  def test_rust_file_is_an_input
    list = inputs("hooked.rmcp.rb")
    assert_includes list, File.join(EXAMPLES, "hooked.rmcp.rb")
    assert_includes list, File.join(EXAMPLES, "rust", "shout.rs")
  end

  def test_openapi_is_an_input
    list = inputs("shopkit.rmcp.rb")
    assert_includes list, File.join(EXAMPLES, "shopkit.openapi.json")
  end

  def test_the_binding_notice_carries_a_digest
    _out, err, status = Open3.capture3(RbConfig.ruby, EXE, "check", File.join(EXAMPLES, "bindings.rmcp.rb"))
    assert status.success?, err
    assert_match(/N-BINDING: bindings\/heck\.rb \(sha256 [0-9a-f]{12}\)/, err)
  end

  def test_json_check_carries_inputs
    out, err, status = Open3.capture3(RbConfig.ruby, EXE, "check", File.join(EXAMPLES, "bindings.rmcp.rb"), "--format", "json")
    assert status.success?, err
    doc = JSON.parse(out)
    assert_includes doc["inputs"], File.join(EXAMPLES, "bindings", "heck.rb")
  end
end
