# expect: `list(...)` cannot hold `map(...)` yet
server "refuse", version: "0.1.0" do
  params :P do
    field :m, list(map(:i64))
  end
  tool :t, params: :P, description: "x" do
    body do |m|
      m.size.to_s
    end
  end
  transport :stdio
end
