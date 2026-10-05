# expect: `port:` must be 0 to 65535, got 70000
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      t
    end
  end
  transport :http, port: 70000
end
