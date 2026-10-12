# frozen_string_literal: true

# A list field can take a `default:` -- a literal list of its items, or [] -- so the body always has a list and an
# optional list no longer needs `optional: true` plus `|| []` wherever it is read (rmcp-for-blender gap #15).
#
#   ruby -Ilib test/test_list_defaults.rb              # the emitted Rust and the refusals
#   RMCP_CARGO=1 ruby -Ilib test/test_list_defaults.rb # also cargo-checks the crate (make test-ruby-rust)
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "rmcp_dsl"

class TestListDefaults < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)

  SRC = <<~'RB'
    server "s", version: "0.1.0" do
      params :P do
        field :tags, :string_list, default: ["a", "b"]
        field :ids, :i64_list, default: []
        field :weights, :f64_list, default: [1, 2.5], max_items: 3
      end

      tool :t, params: :P, description: "d" do
        body do |tags, ids, weights|
          "#{tags.join(',')} #{ids.length} #{weights.length}"
        end
      end

      transport :stdio
    end
  RB

  def with_source(source)
    Dir.mktmpdir("list-defaults") do |dir|
      file = File.join(dir, "s.rmcp.rb")
      File.write(file, source)
      RmcpDsl::Notify.reset!
      yield file
    end
  end

  def test_a_list_default_is_emitted_as_a_vec
    with_source(SRC) do |file|
      _out, err, status = Open3.capture3(RbConfig.ruby, EXE, "check", file)
      assert status.success?, err
      main = RmcpDsl::Emit.files(RmcpDsl.read(file), file)["src/main.rs"]
      assert_includes main, "vec![\"a\".to_string(), \"b\".to_string()]"
      assert_includes main, "vec![]"
      assert_includes main, "vec![1.0, 2.5]"
    end
  end

  def refusal(line)
    source = SRC.sub('field :ids, :i64_list, default: []', line)
    with_source(source) { |file| assert_raises(RmcpDsl::CompileError) { RmcpDsl.read(file) }.message }
  end

  def test_items_must_be_the_lists_element_type
    assert_match(/must be a list of integers/, refusal('field :ids, :i64_list, default: ["1"]'))
  end

  def test_a_default_respects_max_items
    assert_match(/more items than `max_items:`/, refusal('field :ids, :i64_list, default: [1, 2], max_items: 1'))
  end

  def test_a_scalar_field_refuses_a_list
    assert_match(/not a list/, refusal('field :ids, :i64, default: [1]'))
  end

  def test_the_emitted_crate_compiles
    skip "set RMCP_CARGO=1 to cargo-check the emitted crate (make test-ruby-rust)" unless ENV["RMCP_CARGO"]
    with_source(SRC) do |file|
      out = File.join(File.dirname(file), "out")
      _o, err, status = Open3.capture3(RbConfig.ruby, EXE, "build", file, "-o", out)
      assert status.success?, err
      _o, err, status = Open3.capture3("cargo", "check", "-q", chdir: out)
      assert status.success?, "cargo check refused the emitted crate:\n#{err}"
    end
  end
end
