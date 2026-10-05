# expect: is not allowed in a URI
server "refuse", version: "0.1.0" do
  params :P do
    field :id, :string
  end
  resource :r, uri: "x://a<b" do
    body do |id|
      "text#{id}"
    end
  end
  transport :stdio
end
