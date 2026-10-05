# expect: applies to numeric fields
server "refuse", version: "0.1.0" do
  use_bindings :json
  params :P do
    field :doc, Json::Value, min: 1
  end
  tool :t, params: :P, description: "x" do
    body do |doc|
      "x"
    end
  end
  transport :stdio
end
