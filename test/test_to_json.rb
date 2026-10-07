# frozen_string_literal: true

# A typed map can be written as JSON in the body (`to_json`), which is how a request object is built. A value
# serde cannot write ends the call with an error result, not a silent empty string.
#
#   ruby -Ilib test/test_to_json.rb
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "rmcp_dsl"

class TestToJson < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)

  SRC = <<~RB
    server "s", version: "0.1.0" do
      params :P do
        field :s, :string
      end

      tool :t, params: :P, description: "d" do
        body do |s|
          m = { "code" => s }
          m.to_json
        end
      end

      transport :stdio
    end
  RB

  def test_to_json_serializes_a_map_and_is_fallible
    Dir.mktmpdir do |dir|
      file = File.join(dir, "s.rmcp.rb")
      File.write(file, SRC)
      _out, err, status = Open3.capture3(RbConfig.ruby, EXE, "check", file)
      assert status.success?, err
      main = RmcpDsl::Emit.files(RmcpDsl.read(file), file)["src/main.rs"]
      assert_includes main, "rmcp::serde_json::to_string"
      assert_includes main, "json: {e}"
    end
  end
end
