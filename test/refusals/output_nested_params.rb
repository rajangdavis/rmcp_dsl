# expect: output `P` is not declared above this field
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  output :Out do
    field :a, :P
  end
  tool :t, params: :P, output: :Out, description: "x" do
    body do |t|
      result(:Out, a: t)
    end
  end
  transport :stdio
end
