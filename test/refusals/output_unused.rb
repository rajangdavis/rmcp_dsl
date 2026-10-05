# expect: output `Out` is declared but no tool returns it
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  output :Out do
    field :a, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      t
    end
  end
  transport :stdio
end
