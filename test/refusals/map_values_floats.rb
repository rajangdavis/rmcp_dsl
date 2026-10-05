# expect: `values` needs a map of strings or integers
server "refuse", version: "0.1.0" do
  params :P do
    field :m, map(:f64)
  end
  tool :t, params: :P, description: "x" do
    body do |m|
      m.values.join(",")
    end
  end
  transport :stdio
end
