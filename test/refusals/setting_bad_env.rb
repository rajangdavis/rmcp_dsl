# expect: is an environment variable name in capitals
server "refuse", version: "0.1.0" do
  setting :k, env: "api-key"
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
