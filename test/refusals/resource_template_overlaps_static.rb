# expect: can match the same uri
server "refuse", version: "0.1.0" do
  params :P do
    field :id, :string
  end
  resource :latest, uri: "x://notes/latest" do
    body do
      "latest"
    end
  end
  resource :a, uri: "x://notes/{id}", params: :P do
    body do |id|
      id
    end
  end
  transport :stdio
end
