# expect: is already the name of a params struct
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  output :P do
    field :a, :string
  end
  output :Out do
    field :a, :string
  end
  tool :t, params: :P, output: :Out, description: "x" do
    body do |t|
      result(:Out, a: t)
    end
  end
  transport :stdio
end
