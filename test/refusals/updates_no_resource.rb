# expect: but no resource serves that uri (declared: x://r/{t})
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
  tool :t, params: :P, description: "x", updates: ["x://other"] do
    body do |t|
      t
    end
  end
  transport :stdio
end
