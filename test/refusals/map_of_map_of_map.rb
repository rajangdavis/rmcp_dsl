# expect: maps nest one level, as in map(map(:i64))
server "refuse", version: "0.1.0" do
  params :P do
    field :m, map(map(map(:i64)))
  end
  tool :t, params: :P, description: "x" do
    body do |m|
      m.size.to_s
    end
  end
  transport :stdio
end