# frozen_string_literal: true

# A binding can return `T::Array[Float]`: it types as `Vec<f64>` and a body can read it as a float list,
# so a numeric array parsed from JSON need not come back as an opaque value.
#
#   ruby -Ilib test/test_float_array_binding.rb
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "rmcp_dsl"

class TestFloatArrayBinding < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)

  BINDING = <<~RB
    # typed: true
    module Nums
      extend T::Sig
      extend RmcpDsl::BindingDsl

      rust "s.split(',').filter_map(|p| p.trim().parse::<f64>().ok()).collect::<Vec<f64>>()"
      sig { params(s: String).returns(T::Array[Float]) }
      def self.parse(s) = s.split(",").map(&:to_f)
      example :parse, "1,2.5", expect: [1.0, 2.5]
    end
  RB

  SRC = <<~RB
    server "s", version: "0.1.0" do
      use_bindings :nums
      params :P do
        field :s, :string
      end

      tool :t, params: :P, description: "d" do
        body do |s|
          Nums.parse(s).length.to_s
        end
      end

      transport :stdio
    end
  RB

  def test_a_float_array_return_types_as_vec_f64
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "bindings"))
      File.write(File.join(dir, "bindings", "nums.rb"), BINDING)
      file = File.join(dir, "s.rmcp.rb")
      File.write(file, SRC)
      _out, err, status = Open3.capture3(RbConfig.ruby, EXE, "check", file)
      assert status.success?, err
      main = RmcpDsl::Emit.files(RmcpDsl.read(file), file)["src/main.rs"]
      assert_includes main, "-> Vec<f64>"
    end
  end
end
