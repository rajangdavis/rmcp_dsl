# expect: `auth_setting:` and `oauth_issuer:` are two ways to authenticate /mcp; use one
server "refuse", version: "0.1.0" do
  setting :iss, env: "ISS"
  setting :aud, env: "AUD"
  setting :tok, env: "TOK", secret: true
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      t
    end
  end
  transport :http, port: 8766, auth_setting: :tok, oauth_issuer: :iss, oauth_audience: :aud
end
