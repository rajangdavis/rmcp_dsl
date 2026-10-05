# expect: the default for a nil-able Json::Value must be another Json::Value
server "refuse", version: "0.1.0" do
  use_bindings :json
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      doc = Json.parse(text) || "none"
      Json.kind(doc)
    end
  end
  transport :stdio
end
