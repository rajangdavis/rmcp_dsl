# expect: has a `}` with no `{` before it
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
  tool :t, params: :P, description: "x", updates: ["x://r/t}"] do
    body do |t|
      t
    end
  end
  transport :stdio
end
