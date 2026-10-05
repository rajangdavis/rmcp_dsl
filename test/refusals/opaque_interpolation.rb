# expect: is an opaque value; pass it to a function of its binding
server "refuse", version: "0.1.0" do
  use_bindings :json
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      doc = Json.parse(text) || raise("no")
      "got #{doc}"
    end
  end
  transport :stdio
end
