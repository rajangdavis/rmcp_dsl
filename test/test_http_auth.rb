# frozen_string_literal: true

# What `transport :http` emits for each way of protecting /mcp: nothing, a bearer token, or OAuth (with and without a
# declared public URL). The end-to-end scripts (make e2e-httpauth, e2e-httpoauth) run the result; this pins the shapes
# they do not reach, such as the Host-header fallback, and that no parameter is left unused for rustc to warn about.
#
#   ruby -Ilib test/test_http_auth.rb
require "minitest/autorun"
require "rmcp_dsl"
require "tmpdir"

class TestHttpAuth < Minitest::Test
  def source(transport, settings)
    <<~RB
      server "authed", version: "0.1.0" do
      #{settings.map { |s| "  #{s}" }.join("\n")}
        params :P do
          field :t, :string
        end
        tool :t, params: :P, description: "x" do
          body do |t|
            t
          end
        end
        #{transport}
      end
    RB
  end

  def emit(transport, settings = [])
    Dir.mktmpdir("http-auth") do |dir|
      path = File.join(dir, "authed.rmcp.rb")
      File.write(path, source(transport, settings))
      RmcpDsl::Notify.reset!
      return RmcpDsl::Emit.files(RmcpDsl.read(path), path)["src/main.rs"]
    end
  end

  OAUTH = ['setting :iss, env: "ISS"', 'setting :aud, env: "AUD"'].freeze

  def test_plain_http_has_no_layer
    rs = emit("transport :http, port: 8765")
    refute_includes rs, "from_fn"
    refute_includes rs, "require_bearer"
  end

  def test_bearer_wraps_the_mcp_service_in_a_layer
    rs = emit("transport :http, port: 8765, auth_setting: :tok", ['setting :tok, env: "TOK", secret: true'])
    assert_includes rs, ".layer(axum::middleware::from_fn(require_bearer))"
    assert_includes rs, "constant_time_eq"
    refute_includes rs, "require_oauth"
  end

  def test_oauth_serves_the_metadata_outside_the_layer
    rs = emit("transport :http, port: 8765, oauth_issuer: :iss, oauth_audience: :aud", OAUTH)
    layer = rs.index(".layer(axum::middleware::from_fn(require_oauth))") or flunk "no OAuth layer"
    route = rs.index('.route("/.well-known/oauth-protected-resource"') or flunk "no metadata route"
    assert_operator layer, :<, route, "the metadata route must come after the layer so the layer does not wrap it"
    assert_includes rs, "jsonwebtoken::Algorithm::RS256 | jsonwebtoken::Algorithm::ES256"
  end

  def test_oauth_without_a_public_url_uses_loopback_and_never_the_host_header
    rs = emit("transport :http, port: 8765, oauth_issuer: :iss, oauth_audience: :aud", OAUTH)
    assert_includes rs, "fn resource_base() -> String"
    assert_includes rs, %q(format!("http://127.0.0.1:8765"))
    refute_includes rs, "axum::http::header::HOST"
  end

  def test_oauth_with_a_public_url_reads_the_setting
    rs = emit("transport :http, port: 8765, oauth_issuer: :iss, oauth_audience: :aud, oauth_resource: :url",
              [*OAUTH, 'setting :url, env: "URL", default: "http://127.0.0.1:8765"'])
    assert_includes rs, "settings().url.trim_end_matches("
    refute_includes rs, "axum::http::header::HOST"
  end

  def test_oauth_finds_the_issuer_by_rfc_8414_before_openid_connect
    rs = emit("transport :http, port: 8765, oauth_issuer: :iss, oauth_audience: :aud", OAUTH)
    assert_operator rs.index("/.well-known/oauth-authorization-server"), :<, rs.index("/.well-known/openid-configuration")
    assert_includes rs, "/.well-known/jwks.json"
  end

  def test_a_failed_jwks_fetch_still_counts_as_an_attempt_and_keeps_the_held_key
    rs = emit("transport :http, port: 8765, oauth_issuer: :iss, oauth_audience: :aud", OAUTH)
    assert_includes rs, "JWKS_ATTEMPT"
    assert_includes rs, "Err(_) => hit"
  end

  def test_both_layers_match_the_bearer_scheme_without_regard_to_case
    bearer = emit("transport :http, port: 8765, auth_setting: :tok", ['setting :tok, env: "TOK", secret: true'])
    oauth = emit("transport :http, port: 8765, oauth_issuer: :iss, oauth_audience: :aud", OAUTH)
    [bearer, oauth].each do |rs|
      assert_includes rs, "scheme.eq_ignore_ascii_case(\"bearer\")"
      assert_includes rs, ".and_then(bearer_token)"
      refute_includes rs, %q(strip_prefix("Bearer "))
    end
  end

  def test_oauth_adds_the_crates_it_uses
    ir = Dir.mktmpdir("http-auth") do |dir|
      path = File.join(dir, "authed.rmcp.rb")
      File.write(path, source("transport :http, port: 8765, oauth_issuer: :iss, oauth_audience: :aud", OAUTH))
      RmcpDsl::Notify.reset!
      RmcpDsl.read(path)
    end
    assert_equal %w[jsonwebtoken serde_json ureq], ir["crates"].map { |c| c["name"] }.sort
  end
end
