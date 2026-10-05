# expect: map keys are strings, got Integer
server "refuse", version: "0.1.0" do
  params :P do
    field :m, map(:i64)
  end
  tool :t, params: :P, description: "x" do
    body do |m|
      "#{m[1]}"
    end
  end
  transport :stdio
end
