# expect: resource arguments come from the URI, so they are strings; `id` is :i32
server "refuse", version: "0.1.0" do
  params :P do
    field :id, :i32
  end
  resource :r, uri: "x://a/{id}", params: :P do
    body do |id|
      "text#{id}"
    end
  end
  transport :stdio
end
