# expect: refers to undeclared params `Nope`
server "refuse", version: "0.1.0" do
  params :P do
    field :id, :string
  end
  resource :r, uri: "x://a/{id}", params: :Nope do
    body do |id|
      "text#{id}"
    end
  end
  transport :stdio
end
