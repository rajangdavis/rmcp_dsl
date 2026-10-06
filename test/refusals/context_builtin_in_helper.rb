# expect: `client_name` reads the request context, which only a tool body can do, not a helper `h` body
server "refuse", version: "0.1.0" do
  helper :h, args: [], returns: :string do
    client_name || "x"
  end
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x" do
    body do |t|
      h
    end
  end
  transport :stdio
end
