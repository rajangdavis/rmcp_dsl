# expect: the split limit must be an integer literal
server "refuse", version: "0.1.0" do
  params :P do
    field :text, :string
    field :n, :i32
  end
  tool :t, params: :P, description: "x" do
    body do |text, n|
      text.split(",", n).join("|")
    end
  end
  transport :stdio
end
