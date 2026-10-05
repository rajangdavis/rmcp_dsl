# expect: an optional nested object is not supported yet
server "refuse", version: "0.1.0" do
  params :Inner do
    field :a, :string
  end
  params :P do
    field :inner, :Inner, optional: true
  end
  tool :t, params: :P, description: "x" do
    body do |inner|
      "#{inner}"
    end
  end
  transport :stdio
end
