# frozen_string_literal: true

# An MCP tool can take no arguments: `params :NoArgs do end` is allowed and emits an empty struct,
# so a tool whose argument object is `{}` is expressible.
#
#   ruby -Ilib test/test_empty_params.rb
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "rmcp_dsl"

class TestEmptyParams < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)

  SRC = <<~RB
    server "s", version: "0.1.0" do
      params :NoArgs do
      end

      tool :ping, params: :NoArgs, description: "Ping" do
        body do
          "pong"
        end
      end

      transport :stdio
    end
  RB

  def test_an_empty_params_checks_and_emits_an_empty_struct
    Dir.mktmpdir do |dir|
      file = File.join(dir, "s.rmcp.rb")
      File.write(file, SRC)
      _out, err, status = Open3.capture3(RbConfig.ruby, EXE, "check", file)
      assert status.success?, err
      main = RmcpDsl::Emit.files(RmcpDsl.read(file), file)["src/main.rs"]
      assert_includes main, "struct NoArgs {"
      assert_includes main, "fn ping("
    end
  end
end
