# expect: `min:` applies to numeric fields, not :string
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string, min: 1
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      text
    end
  end
  transport :stdio
end
