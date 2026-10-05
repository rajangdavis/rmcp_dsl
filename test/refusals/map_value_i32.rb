# expect: map values use :i64 for integers
server "refuse", version: "0.1.0" do
  params :P do
    field :m, map(:i32)
  end
  tool :t, params: :P, description: "x" do
    body do |m|
      m.size.to_s
    end
  end
  transport :stdio
end
