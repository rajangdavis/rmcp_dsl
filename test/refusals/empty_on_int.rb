# expect: unsupported method `empty?` in body
server "refuse", version: "0.1.0" do
  params :P do
    field :n, :i32
  end
  tool :t, params: :P, description: "x" do
    body do |n|
      if n.empty? then "y" else "n" end
    end
  end
  transport :stdio
end
