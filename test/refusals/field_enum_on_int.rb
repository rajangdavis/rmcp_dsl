# expect: `enum:` applies to :string fields, not :i32
server "refuse", version: "0.1.0" do
  params :P do
    field :n, :i32, enum: ["a"]
  end
  tool :t, params: :P, description: "x" do
    body do |n|
      n.to_s
    end
  end
  transport :stdio
end
