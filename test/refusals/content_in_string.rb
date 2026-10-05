# expect: a content block cannot go inside a string
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      "x #{text(t)}"
    end
  end
  transport :stdio
end
