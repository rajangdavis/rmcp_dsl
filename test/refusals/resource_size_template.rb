# expect: `size:` is for a resource with one fixed uri
server "refuse", version: "0.1.0" do
  params :P do
    field :id, :string
  end
  resource :r, uri: "x://r/{id}", params: :P, size: 5 do
    body do |id|
      id
    end
  end
  transport :stdio
end
