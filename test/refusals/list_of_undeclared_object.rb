# expect: is not declared above this field
server "refuse", version: "0.1.0" do
  params :P do
    field :items, list(:Address)
  end
  tool :t, params: :P, description: "x" do
    body do |items|
      items.length.to_s
    end
  end
  transport :stdio
end