# expect: can match the same uri
server "refuse", version: "0.1.0" do
  params :P do
    field :a, :string, optional: true
  end
  resource :plain, uri: "x://a" do
    body do
      "plain"
    end
  end
  resource :search, uri: "x://a{?a}", params: :P do
    body do |a|
      "text#{a || "-"}"
    end
  end
  transport :stdio
end
