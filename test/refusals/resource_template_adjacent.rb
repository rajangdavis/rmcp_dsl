# expect: touch; put text between them
server "refuse", version: "0.1.0" do
  params :P do
    field :id, :string
    field :b, :string
  end
  resource :r, uri: "x://a/{id}{b}", params: :P do
    body do |id, b|
      "text#{id}"
    end
  end
  transport :stdio
end
