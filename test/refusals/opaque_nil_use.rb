# expect: this value may be nil; use `|| default`, `.nil?` or `.to_s` (not `kind`)
server "refuse", version: "0.1.0" do
  use_bindings :json
  params :P do
    field :text, :string
  end
  tool :t, params: :P, description: "x" do
    body do |text|
      Json.parse(text).kind
    end
  end
  transport :stdio
end
