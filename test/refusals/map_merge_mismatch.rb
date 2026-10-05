# expect: `merge` takes a map of the same kind
server "refuse", version: "0.1.0" do
  params :P do
    field :m, map(:i64)
  end
  tool :t, params: :P, description: "x" do
    body do |m|
      m.merge({ "a" => "x" }).size.to_s
    end
  end
  transport :stdio
end
