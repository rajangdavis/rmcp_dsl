# expect: `raise` needs a string message, got i32
server "refuse", version: "0.1.0" do
  params :P do
    field :n, :i32
  end
  tool :t, params: :P, description: "x" do
    body do |n|
      n > 1 ? raise(n) : "ok"
    end
  end
  transport :stdio
end
