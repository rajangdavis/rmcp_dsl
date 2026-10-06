# expect: `auth_setting:` only applies to `transport :http`
server "refuse", version: "0.1.0" do
  setting :tok, env: "TOK", secret: true
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      t
    end
  end
  transport :stdio, auth_setting: :tok
end
