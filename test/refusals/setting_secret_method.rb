# expect: a secret has no methods (not `length`)
server "refuse", version: "0.1.0" do
  setting :k, env: "K", secret: true
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      setting(:k).length.to_s
    end
  end
  transport :stdio
end
