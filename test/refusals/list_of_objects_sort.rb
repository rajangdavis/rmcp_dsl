# expect: not `sort`
server "refuse", version: "0.1.0" do
  params :Address do
    field :city, :string
  end
  params :P do
    field :items, list(:Address)
  end
  tool :t, params: :P, description: "x" do
    body do |items|
      items.sort.length.to_s
    end
  end
  transport :stdio
end