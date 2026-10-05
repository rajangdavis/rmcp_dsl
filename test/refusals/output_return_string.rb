# expect: `return` needs a struct:Out value, got str
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  output :Out do
    field :a, :string
  end
  tool :t, params: :P, output: :Out, description: "x" do
    body do |t|
      return "no" if t.empty?
      result(:Out, a: t)
    end
  end
  transport :stdio
end
