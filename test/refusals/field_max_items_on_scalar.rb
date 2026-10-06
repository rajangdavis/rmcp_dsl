# expect: `max_items:` applies to list fields, not :string
server "refuse", version: "0.1.0" do
  params :P do
    field :s, :string, max_items: 1
  end
  tool :t, params: :P, description: "x" do
    body do |s|
      "#{s}"
    end
  end
  transport :stdio
end
