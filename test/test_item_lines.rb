# frozen_string_literal: true

# The reader records the DSL line each `rust_item` snippet starts on (`item_lines`, parallel to `items`), so a
# diagnostic in the generated crate's injected Rust can be mapped back to the DSL file.
#
#   ruby -Ilib test/test_item_lines.rb
require "minitest/autorun"
require "rmcp_dsl"
require "tmpdir"

class TestItemLines < Minitest::Test
  SOURCE = <<~'RB'
    server "lines", version: "0.1.0" do
      rust_item <<~'RS'
        fn one(x: i64) -> i64 { x + 1 }
      RS
      rust_item <<~'RS'
        fn two(x: i64) -> i64 {
            x + 2
        }
      RS
      rust_fn :one, args: [:i64], returns: :i64
      rust_fn :two, args: [:i64], returns: :i64

      params :P do
        field :n, :i64
      end

      tool :run, params: :P, description: "d" do
        body do |n|
          (rust(:one, n) + rust(:two, n)).to_s
        end
      end

      transport :stdio
    end
  RB

  def read_source(source)
    Dir.mktmpdir("item-lines") do |dir|
      path = File.join(dir, "lines.rmcp.rb")
      File.write(path, source)
      RmcpDsl::Notify.reset!
      return RmcpDsl.read(path)
    end
  end

  def test_each_item_records_the_line_its_text_starts_on
    ir = read_source(SOURCE)
    assert_equal 2, ir["items"].size
    assert_equal [3, 6], ir["item_lines"]
  end

  def test_item_lines_stay_parallel_to_items
    ir = read_source(SOURCE)
    assert_equal ir["items"].size, ir["item_lines"].size
  end
end
