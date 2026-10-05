# expect: Inner has no field `zzz`
server "refuse", version: "0.1.0" do
  params :Inner do
    field :a, :string
  end
  params :P do
    field :inner, :Inner
  end
  tool :t, params: :P, description: "x" do
    body do |inner|
      "#{inner.zzz}"
    end
  end
  transport :stdio
end
