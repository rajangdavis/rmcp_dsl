# expect: only supports
server "refuse", version: "0.1.0" do
  params :Address do
    field :city, :string
  end
  params :P do
    field :m, map(:Address)
  end
  tool :t, params: :P, description: "x" do
    body do |m|
      m.values.sum.to_s
    end
  end
  transport :stdio
end
