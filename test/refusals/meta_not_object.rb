# expect: `meta:` is a JSON object written as a literal
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end
  tool :t, params: :P, description: "x", meta: "x" do
    body do |t|
      t
    end
  end
  transport :stdio
end
