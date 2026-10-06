# expect: `oauth_issuer:` names `iss`, which is a secret
server "refuse", version: "0.1.0" do
  setting :iss, env: "ISS", secret: true
  setting :aud, env: "AUD"
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      t
    end
  end
  transport :http, port: 8766, oauth_issuer: :iss, oauth_audience: :aud
end
