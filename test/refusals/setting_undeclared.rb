# expect: no setting `nope` is declared (declared: v)
server "refuse", version: "0.1.0" do
  setting :v, env: "V"
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      setting(:nope)
    end
  end
  transport :stdio
end
