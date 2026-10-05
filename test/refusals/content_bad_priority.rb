# expect: a number from 0 to 1 written out
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      text(t, priority: 2)
    end
  end
  transport :stdio
end
