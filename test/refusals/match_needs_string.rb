# expect: `=~` needs a string receiver
server "refuse", version: "0.1.0" do
  params :P do
    field :n, :i32
  end
  tool :t, params: :P, description: "x" do
    body do |n|
      n =~ /2/
    end
  end
  transport :stdio
end
