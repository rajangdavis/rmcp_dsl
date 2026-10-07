# frozen_string_literal: true

# `transport :http` can name a bind address and the Host values its DNS-rebinding check accepts, so a caller
# that is not on loopback (a container, another machine) can reach the server.
#
#   ruby -Ilib test/test_http_hosts.rb
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "rmcp_dsl"

class TestHttpHosts < Minitest::Test
  EXE = File.expand_path("../exe/rmcp_dsl", __dir__)

  SRC = <<~RB
    server "s", version: "0.1.0" do
      params :P do
        field :s, :string
      end

      tool :t, params: :P, description: "d" do
        body do |s|
          s
        end
      end

      transport :http, port: 8787, bind: "0.0.0.0", allowed_hosts: ["host.docker.internal"],
                allowed_origins: ["https://app.example.com"], json_response: true, stateless: true,
                sse_keep_alive: 15, sse_retry: 3, max_body_bytes: 2_000_000
    end
  RB

  def test_bind_and_allowed_hosts_reach_the_generated_main
    Dir.mktmpdir do |dir|
      file = File.join(dir, "s.rmcp.rb")
      File.write(file, SRC)
      _out, err, status = Open3.capture3(RbConfig.ruby, EXE, "check", file)
      assert status.success?, err
      main = RmcpDsl::Emit.files(RmcpDsl.read(file), file)["src/main.rs"]
      assert_includes main, ".with_allowed_hosts([\"host.docker.internal\"])"
      assert_includes main, ".with_allowed_origins([\"https://app.example.com\"])"
      assert_includes main, ".with_json_response(true)"
      assert_includes main, ".with_legacy_session_mode(false)"
      assert_includes main, ".with_sse_keep_alive(Some(std::time::Duration::from_secs(15)))"
      assert_includes main, ".with_sse_retry(Some(std::time::Duration::from_secs(3)))"
      assert_includes main, ".with_max_request_body_bytes(2000000)"
      assert_includes main, "TcpListener::bind(\"0.0.0.0:8787\")"
    end
  end
end
