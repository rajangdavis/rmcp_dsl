# typed: true
# httpauth: a streamable HTTP server that only answers requests carrying `Authorization: Bearer <token>`. The token is
# a secret setting (read from HTTPAUTH_TOKEN at startup, never printed or returned), and `auth_setting:` on the
# transport puts a layer in front of /mcp: no header or a wrong token is a 401 with a `WWW-Authenticate: Bearer`
# challenge, before rmcp sees the request. One tool is plain Ruby; the other calls Rust injected with rust_item.
server "httpauth", version: "0.1.0", instructions: "Reverse text, or shout it, behind a bearer token" do
  setting :api_token, env: "HTTPAUTH_TOKEN", secret: true, description: "the bearer token every request must carry"

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

  transport :http, port: 8765, auth_setting: :api_token
end
