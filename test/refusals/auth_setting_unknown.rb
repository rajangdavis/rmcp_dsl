# expect: `auth_setting:` names setting `nope`, which is not declared
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      t
    end
  end
  transport :http, port: 8765, auth_setting: :nope
end
