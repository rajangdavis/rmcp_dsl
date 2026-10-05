# expect: `fetch` takes one or two arguments on a map
server "refuse", version: "0.1.0" do
  params :P do
    field :m, map(:i64)
  end
  tool :t, params: :P, description: "x" do
    body do |m|
      m.fetch.to_s
    end
  end
  transport :stdio
end
