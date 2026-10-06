# expect: `oauth_issuer:` only applies to `transport :http`
server "refuse", version: "0.1.0" do
  setting :iss, env: "ISS"
  setting :aud, env: "AUD"
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      t
    end
  end
  transport :stdio, oauth_issuer: :iss, oauth_audience: :aud
end
