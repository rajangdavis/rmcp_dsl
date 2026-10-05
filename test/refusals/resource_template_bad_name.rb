# expect: is not a valid RFC 6570 variable name
server "refuse", version: "0.1.0" do
  params :P do
    field :id, :string
  end
  resource :r, uri: "x://a/{i-d}", params: :P do
    body do |id|
      "text#{id}"
    end
  end
  transport :stdio
end
