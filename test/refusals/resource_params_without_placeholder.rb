# expect: `params:` only applies to a `uri:` with {placeholders}
server "refuse", version: "0.1.0" do
  params :P do
    field :id, :string
  end
  resource :r, uri: "x://a", params: :P do
    body do |id|
      "text#{id}"
    end
  end
  transport :stdio
end
