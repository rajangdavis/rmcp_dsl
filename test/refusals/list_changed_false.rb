# expect: `resource_list_changed: false` is the default
server "refuse", version: "0.1.0" do
  params :Q do
    field :t, :string
  end
  params :P do
    field :t, :string
    field :n, :i64
  end
  resource :r, uri: "x://r/{t}", params: :Q do
    body do |t|
      t
    end
  end
  tool :t, params: :P, description: "x", resource_list_changed: false do
    body do |t|
      t
    end
  end
  transport :stdio
end
