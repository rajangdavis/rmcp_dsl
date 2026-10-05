# expect: map keys are strings: write "a" => value
server "refuse", version: "0.1.0" do
  params :P do
    field :m, map(:i64)
  end
  tool :t, params: :P, description: "x" do
    body do |m|
      { a: 1 }.size.to_s
    end
  end
  transport :stdio
end
