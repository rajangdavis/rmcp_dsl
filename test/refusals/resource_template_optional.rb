# expect: do not apply to `id`
server "refuse", version: "0.1.0" do
  params :P do
    field :id, :string, optional: true
  end
  resource :r, uri: "x://a/{id}", params: :P do
    body do |id|
      "text#{id}"
    end
  end
  transport :stdio
end
