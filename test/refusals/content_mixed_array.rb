# expect: array elements must all be strings, all be integers or all be content blocks
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      ["a", text(t)]
    end
  end
  transport :stdio
end
