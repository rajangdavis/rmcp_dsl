# expect: is a list, so `a` is a :string_list, not :string
server "refuse", version: "0.1.0" do
  params :P do
    field :a, :string
  end
  resource :r, uri: "x://a/{a*}", params: :P do
    body do |a|
      "text#{a}"
    end
  end
  transport :stdio
end
