# expect: `a:` of Out needs a string, got int
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  output :Out do
    field :a, :string
    field :b, :i64
  end
  tool :t, params: :P, output: :Out, description: "x" do
    body do |t|
      result(:Out, a: 1, b: 1)
    end
  end
  transport :stdio
end
