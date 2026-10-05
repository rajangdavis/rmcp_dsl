# expect: `tally` needs a list of strings
server "refuse", version: "0.1.0" do
  params :P do
    field :n, :i64_list
  end
  tool :t, params: :P, description: "x" do
    body do |n|
      n.tally.size.to_s
    end
  end
  transport :stdio
end
