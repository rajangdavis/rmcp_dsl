# expect: `multiple_of:` applies to :i32 and :i64 fields, not :f64
server "refuse", version: "0.1.0" do
  params :P do
    field :n, :f64, multiple_of: 2
  end
  tool :t, params: :P, description: "x" do
    body do |n|
      n.to_s
    end
  end
  transport :stdio
end
