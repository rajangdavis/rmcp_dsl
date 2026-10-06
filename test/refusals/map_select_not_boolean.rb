# expect: block must return true or false
server "refuse", version: "0.1.0" do
  params :P do
    field :m, map(:i64)
  end
  tool :t, params: :P, description: "x" do
    body do |m|
      m.select { |k, v| k }
    end
  end
  transport :stdio
end
