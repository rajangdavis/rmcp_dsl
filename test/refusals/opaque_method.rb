# expect: is an opaque value with no methods of its own (not `length`)
server "refuse", version: "0.1.0" do
  use_bindings :json
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      doc = Json.parse(text) || raise("no")
      doc.length
    end
  end
  transport :stdio
end
