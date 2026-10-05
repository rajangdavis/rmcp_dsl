# expect: `gsub` with a block takes one regex literal as its pattern
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      text.gsub("a") { |m| m }
    end
  end
  transport :stdio
end
