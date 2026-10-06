# expect: `each` takes a block with exactly one plain parameter
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      text.split(",").each { |a, b| a }
      text
    end
  end
  transport :stdio
end
