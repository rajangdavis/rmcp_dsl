# expect: a guard clause must end with `return` or `raise`
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      "x" if text.empty?
      text
    end
  end
  transport :stdio
end
