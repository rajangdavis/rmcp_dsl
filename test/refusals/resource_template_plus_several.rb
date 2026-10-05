# expect: `+` takes one variable
server "refuse", version: "0.1.0" do
  params :P do
    field :a, :string
    field :b, :string
  end
  resource :r, uri: "x://a/{+a,b}", params: :P do
    body do |a|
      "text#{a}"
    end
  end
  transport :stdio
end
