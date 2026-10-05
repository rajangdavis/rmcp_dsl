# expect: has a literal `?` and also a `{?...}`
server "refuse", version: "0.1.0" do
  params :P do
    field :a, :string, optional: true
  end
  resource :r, uri: "x://a?z=1{?a}", params: :P do
    body do |a|
      "text#{a}"
    end
  end
  transport :stdio
end
