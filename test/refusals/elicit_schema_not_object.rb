# expect: the elicitation `schema:` must be a JSON object literal
server "refuse", version: "0.1.0" do
  params :P do
    field :t, :string
  end

  tool :t, params: :P, description: "x" do
    body do |t|
      elicit(t, schema: "nope").action
    end
  end

  transport :stdio
end
