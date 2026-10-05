# expect: refers to undeclared output `Nope`
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, output: :Nope, description: "x" do
    body do |t|
      t
    end
  end
  transport :stdio
end
