# frozen_string_literal: true

# A bindings/*.rb that no use_bindings names is never parsed, so its crates never reach Cargo.toml
# and the failure surfaces later as a missing crate in generated Rust. The compiler says so at check
# time, unless a sibling server in the same folder names it (one bindings/ folder can serve several).
#
#   ruby -Ilib test/test_unloaded_binding.rb
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

class TestUnloadedBinding < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)

  def server(*decls)
    <<~RB
      server "s", version: "0.1.0" do
      #{decls.map { |d| "  #{d}" }.join("\n")}
        params :P do
          field :s, :string
        end
        tool :t, params: :P, description: "d" do
          body do |s|
            s
          end
        end
        transport :stdio
      end
    RB
  end

  BINDING = <<~RB
    # typed: true
    module Orphan
      extend T::Sig
      extend RmcpDsl::BindingDsl

      crate "orphan", "1.0"

      rust "s"
      sig { params(s: String).returns(String) }
      def self.go(s) = s
      example :go, "x", expect: "x"
    end
  RB

  def write(dir, name, text)
    path = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  def check(dir, file)
    Open3.capture3(RbConfig.ruby, EXE, File.join(dir, file), "--check")
  end

  def test_an_unloaded_binding_warns
    Dir.mktmpdir do |dir|
      write(dir, "s.rmcp.rb", server)
      write(dir, "bindings/orphan.rb", BINDING)
      _out, err, status = check(dir, "s.rmcp.rb")
      assert status.success?, err
      assert_includes err, "warning W-BINDING-UNLOADED"
      assert_includes err, "bindings/orphan.rb"
    end
  end

  def test_a_sibling_server_that_names_it_is_enough
    Dir.mktmpdir do |dir|
      write(dir, "a.rmcp.rb", server)
      write(dir, "b.rmcp.rb", server("use_bindings :orphan"))
      write(dir, "bindings/orphan.rb", BINDING)
      _out, err, status = check(dir, "a.rmcp.rb")
      assert status.success?, err
      refute_includes err, "W-BINDING-UNLOADED"
    end
  end
end
