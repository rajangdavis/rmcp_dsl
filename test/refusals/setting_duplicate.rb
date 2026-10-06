# expect: duplicate setting `v`
server "refuse", version: "0.1.0" do
  setting :v, env: "V"
  setting :v, env: "W"
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      setting(:v)
    end
  end
  transport :stdio
end
