# expect: text: needs a string, got Integer
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      text(1)
    end
  end
  transport :stdio
end
