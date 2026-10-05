# expect: is not supported yet: collections hold basic types
server "refuse", version: "0.1.0" do
  use_bindings :json
  params :P do
    field :doc, map(Json::Value)
  end
  tool :t, params: :P, description: "x" do
    body do |doc|
      "x"
    end
  end
  transport :stdio
end
