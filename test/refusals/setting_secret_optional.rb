# expect: a secret is either there or the server does not start
server "refuse", version: "0.1.0" do
  setting :k, env: "K", secret: true, optional: true
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
