# expect: `each` needs a list or a map, got String
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      text.each { |c| c }
      text
    end
  end
  transport :stdio
end
