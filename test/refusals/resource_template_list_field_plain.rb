# expect: resource arguments come from the URI, so they are strings; `a` is :string_list
server "refuse", version: "0.1.0" do
  params :P do
    field :a, :string_list
  end
  resource :r, uri: "x://a/{a}", params: :P do
    body do |a|
      "text#{a}"
    end
  end
  transport :stdio
end
