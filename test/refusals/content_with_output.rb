# expect: this tool returns Out; end the body with result(:Out, ...)
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  output :Out do
    field :n, :i64
  end
  tool :t, params: :P, output: :Out, description: "x" do
    body do |t|
      text(t)
    end
  end
  transport :stdio
end
