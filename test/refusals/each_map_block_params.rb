# expect: `each` takes a block with exactly two plain parameters, |k, v|
server "refuse", version: "0.1.0" do
  params :P do
    field :m, map(:i64)
  end
  tool :t, params: :P, description: "x" do
    body do |m|
      m.each { |k| k }
      "ok"
    end
  end
  transport :stdio
end
