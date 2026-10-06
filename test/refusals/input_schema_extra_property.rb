# expect: has a property `z` that is not a field of params `P`
server "refuse", version: "0.1.0" do
  params :P do
    field :q, :string
    field :n, :i64, optional: true
  end
  tool :t, params: :P, description: "x", input_schema: { "type" => "object", "properties" => { "q" => { "type" => "string" }, "n" => { "type" => "integer" }, "z" => { "type" => "string" } }, "required" => ["q"] } do
    body do |q|
      q
    end
  end
  transport :stdio
end
