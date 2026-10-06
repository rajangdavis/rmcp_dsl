# expect: `{items*}` is a list, so `items` is a :string_list, not :f64_list
server "refuse", version: "0.1.0" do
  params :Items do
    field :items, :f64_list
  end
  resource :list, uri: "refuse://items/{items*}", params: :Items do
    body do |items|
      items.join(",")
    end
  end
  transport :stdio
end
