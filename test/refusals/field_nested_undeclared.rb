# expect: params `Inner` is not declared above this field
server "refuse", version: "0.1.0" do
  params :P do
    field :inner, :Inner
  end
  tool :t, params: :P, description: "x" do
    body do |inner|
      "#{inner}"
    end
  end
  transport :stdio
end
