# expect: Out has no field `zzz`
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
      result(:Out, a: t, b: 1, zzz: 2)
    end
  end
  transport :stdio
end
