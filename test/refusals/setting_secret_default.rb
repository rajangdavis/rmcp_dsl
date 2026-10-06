# expect: a secret has no `default:`
server "refuse", version: "0.1.0" do
  setting :k, env: "K", secret: true, default: "x"
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      t
    end
  end
  transport :stdio
end
