# expect: `_meta` key "progressToken" is reserved by MCP
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x", meta: { "progressToken" => "abc" } do
    body do |t|
      t
    end
  end
  transport :stdio
end
