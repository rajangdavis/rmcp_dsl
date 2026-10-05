# expect: can match the same uri
server "refuse", version: "0.1.0" do
  params :P do
    field :id, :string
  end
  params :Q do
    field :name, :string
  end
  resource :a, uri: "x://notes/{id}", params: :P do
    body do |id|
      id
    end
  end
  resource :b, uri: "x://notes/{name}", params: :Q do
    body do |name|
      name
    end
  end
  transport :stdio
end
