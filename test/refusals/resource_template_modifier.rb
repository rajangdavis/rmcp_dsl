# expect: uses the RFC 6570 prefix modifier `:`
server "refuse", version: "0.1.0" do
  params :P do
    field :id, :string
  end
  resource :r, uri: "x://a/{id:3}", params: :P do
    body do |id|
      "text#{id}"
    end
  end
  transport :stdio
end
