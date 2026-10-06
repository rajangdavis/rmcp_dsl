# expect: `oauth_issuer:` and `oauth_audience:` go together
server "refuse", version: "0.1.0" do
  setting :iss, env: "ISS"
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      t
    end
  end
  transport :http, port: 8766, oauth_issuer: :iss
end
