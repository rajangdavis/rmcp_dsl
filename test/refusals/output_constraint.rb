# expect: does not apply to an output field
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  output :Out do
    field :a, :string, min_length: 1
  end
  tool :t, params: :P, output: :Out, description: "x" do
    body do |t|
      result(:Out, a: t)
    end
  end
  transport :stdio
end
