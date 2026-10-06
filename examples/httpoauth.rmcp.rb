# typed: true
# httpoauth: a streamable HTTP server that is an OAuth resource server. Every request to /mcp must carry
# `Authorization: Bearer <JWT>`, signed by the issuer (RS256 or ES256; the key is found by `kid` in the issuer's JWKS) for
# this audience and not expired. Anything else is a 401 whose WWW-Authenticate points at
# /.well-known/oauth-protected-resource, which the server answers without a token so a client can find the issuer.
# The issuer, the audience and the public URL are ordinary settings, none of them a secret.
server "httpoauth", version: "0.1.0", instructions: "Reverse text, or shout it, behind an OAuth access token" do
  setting :issuer, env: "OAUTH_ISSUER", description: "the OAuth issuer URL (its JWKS is fetched from there)"
  setting :audience, env: "OAUTH_AUDIENCE", description: "the audience a token must have been issued for"
  setting :public_url, env: "OAUTH_RESOURCE", default: "http://127.0.0.1:8766", description: "this server's public base URL"

  rust_item <<~'RS'
    fn shout(s: &str) -> String {
        format!("{}!", s.to_uppercase())
    }
  RS
  rust_fn :shout, args: [:string], returns: :string

  params :TextParams do
    field :text, :string, description: "the text"
  end

  tool :reverse, params: :TextParams, description: "The text reversed (plain Ruby)" do
    body do |text|
      text.reverse
    end
  end

  tool :loud, params: :TextParams, description: "The text in capitals with an exclamation mark (injected Rust)" do
    body do |text|
      rust(:shout, text)
    end
  end

  transport :http, port: 8766, oauth_issuer: :issuer, oauth_audience: :audience, oauth_resource: :public_url
end
