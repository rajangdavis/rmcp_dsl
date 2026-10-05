# expect: not `keyz`; did you mean `key?` or `keys`?
server "refuse", version: "0.1.0" do
  params :P do
    field :m, map(:i64)
  end
  tool :t, params: :P, description: "x" do
    body do |m|
      m.keyz.join(",")
    end
  end
  transport :stdio
end
