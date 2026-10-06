# expect: `exclusive_min:` must be an integer for an :i32 field
server "refuse", version: "0.1.0" do
  params :P do
    field :n, :i32, exclusive_min: 0.5
  end
  tool :t, params: :P, description: "x" do
    body do |n|
      n.to_s
    end
  end
  transport :stdio
end
