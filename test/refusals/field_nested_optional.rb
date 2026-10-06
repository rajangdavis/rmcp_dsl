# expect: may be nil, so read its fields with `&.`
server "refuse", version: "0.1.0" do
  params :Inner do
    field :a, :string
  end
  params :P do
    field :inner, :Inner, optional: true
  end
  tool :t, params: :P, description: "x" do
    body do |inner|
      inner.a
    end
  end
  transport :stdio
end
