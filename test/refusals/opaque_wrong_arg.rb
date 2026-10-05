# expect: argument `doc` should be Json::Value, got String
server "refuse", version: "0.1.0" do
  use_bindings :json
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      Json.kind(text)
    end
  end
  transport :stdio
end
