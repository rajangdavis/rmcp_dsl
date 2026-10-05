# expect: which is not supported; write {?x}
server "refuse", version: "0.1.0" do
  params :P do
    field :a, :string, optional: true
  end
  resource :r, uri: "x://a{?a*}", params: :P do
    body do |a|
      "text#{a}"
    end
  end
  transport :stdio
end
