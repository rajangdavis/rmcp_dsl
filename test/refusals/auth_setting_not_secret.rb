# expect: `auth_setting:` needs `tok` to be `secret: true`
server "refuse", version: "0.1.0" do
  setting :tok, env: "TOK"
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      t
    end
  end
  transport :http, port: 8765, auth_setting: :tok
end
