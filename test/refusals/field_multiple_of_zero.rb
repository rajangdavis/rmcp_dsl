# expect: `multiple_of:` must be a positive integer
server "refuse", version: "0.1.0" do
  params :P do
    field :n, :i32, multiple_of: 0
  end
  tool :t, params: :P, description: "x" do
    body do |n|
      n.to_s
    end
  end
  transport :stdio
end
