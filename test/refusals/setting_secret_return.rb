# expect: a secret cannot be returned
server "refuse", version: "0.1.0" do
  setting :k, env: "K", secret: true
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      setting(:k)
    end
  end
  transport :stdio
end
