# expect: `hide_tool` names `nope`, which is not a tool of this server
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end

  tool :t, params: :P, description: "x" do
    body do |t|
      hide_tool(:nope)
      t
    end
  end

  transport :stdio
end
