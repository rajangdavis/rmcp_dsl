# expect: prompt arguments are strings in MCP, but `n` is :i32
server "refuse", version: "0.1.0" do
  params :P do
    field :n, :i32
  end
  tool :t, params: :P, description: "x" do
    body do |n|
      n.to_s
    end
  end
  prompt :p, params: :P, description: "x" do
    body do |n|
      n.to_s
    end
  end
  transport :stdio
end
