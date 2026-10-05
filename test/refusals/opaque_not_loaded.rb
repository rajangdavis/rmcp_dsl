# expect: no binding provides module `Json`
server "refuse", version: "0.1.0" do
  params :P do
    field :doc, Json::Value
  end
  tool :t, params: :P, description: "x" do
    body do |doc|
      "x"
    end
  end
  transport :stdio
end
