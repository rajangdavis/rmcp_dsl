# expect: `hide_tool` hides or shows a tool, which only a tool body can do, not a helper `h` body
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end

  helper :h, args: [], returns: :string do
    hide_tool(:t)
    "x"
  end

  tool :t, params: :P, description: "x" do
    body do |t|
      h
    end
  end

  transport :stdio
end
