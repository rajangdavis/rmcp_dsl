# expect: needs strs
server "refuse", version: "0.1.0" do
  params :Address do
    field :city, :string
  end
  params :P do
    field :items, list(:Address)
  end
  output :Out do
    field :tags, :string_list
  end
  tool :t, params: :P, output: :Out, description: "x" do
    body do |items|
      result(:Out, tags: items)
    end
  end
  transport :stdio
end