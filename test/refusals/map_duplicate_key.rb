# expect: duplicate map key "a"
server "refuse", version: "0.1.0" do
  params :P do
    field :m, map(:i64)
  end
  tool :t, params: :P, description: "x" do
    body do |m|
      { "a" => 1, "a" => 2 }.size.to_s
    end
  end
  transport :stdio
end
