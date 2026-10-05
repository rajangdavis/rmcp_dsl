# expect: did you mean {item_id}?
server "refuse", version: "0.1.0" do
  params :P do
    field :item_id, :string
  end
  resource :r, uri: "x://a/{itemid}", params: :P do
    body do |item_id|
      "text#{item_id}"
    end
  end
  transport :stdio
end
