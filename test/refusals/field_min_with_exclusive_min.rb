# expect: `min:` and `exclusive_min:` both set a lower bound
server "refuse", version: "0.1.0" do
  params :P do
    field :n, :i32, min: 0, exclusive_min: 1
  end
  tool :t, params: :P, description: "x" do
    body do |n|
      n.to_s
    end
  end
  transport :stdio
end
