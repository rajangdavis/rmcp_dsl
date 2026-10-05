# expect: has to end the uri: the query comes last
server "refuse", version: "0.1.0" do
  params :P do
    field :a, :string, optional: true
  end
  resource :r, uri: "x://a{?a}/b", params: :P do
    body do |a|
      "text#{a}"
    end
  end
  transport :stdio
end
