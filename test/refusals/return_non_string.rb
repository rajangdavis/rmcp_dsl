# expect: `return` needs a string value, got int
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      return 5 if text.empty?
      text
    end
  end
  transport :stdio
end
