# expect: expected `gsub(pattern, replacement)`
server "t", version: "0.1.0" do
  params :P do
    field :text, :string
  end

  tool :x, params: :P, description: "d" do
    body do |text|
      text.gsub("a")
    end
  end

  transport :stdio
end
