# expect: field `extra` of params `P` is not in the uri
server "refuse", version: "0.1.0" do
  params :P do
    field :id, :string
    field :extra, :string
  end
  resource :r, uri: "x://a/{id}", params: :P do
    body do |id|
      "text#{id}"
    end
  end
  transport :stdio
end
